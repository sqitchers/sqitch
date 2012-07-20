#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
#use Test::More tests => 17;
use Test::More 'no_plan';
use Test::NoWarnings;
use Path::Class;
use App::Sqitch;
use App::Sqitch::Plan;
use Test::MockModule;
use Digest::SHA1;
use URI;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Tag';
    require_ok $CLASS or die;
    delete $ENV{PGDATABASE};
    delete $ENV{PGUSER};
    delete $ENV{USER};
    $ENV{SQITCH_CONFIG} = 'nonexistent.conf';
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    note
    plan
    timestamp
    planner_name
    planner_email
    format_planner
);

my $sqitch = App::Sqitch->new( top_dir => dir qw(t sql) );
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
my $change = App::Sqitch::Plan::Change->new( plan => $plan, name => 'roles' );

isa_ok my $tag = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
    change  => $change,
), $CLASS;
isa_ok $tag, 'App::Sqitch::Plan::Line';
my $mock_plan = Test::MockModule->new('App::Sqitch::Plan');
$mock_plan->mock(index_of => 0); # no other changes

is $tag->format_name, '@foo', 'Name should format as "@foo"';
isa_ok $tag->timestamp, 'App::Sqitch::DateTime', 'Timestamp';

is $tag->planner_name, $sqitch->user_name,
    'Planner name shoudld default to user name';
is $tag->planner_email, $sqitch->user_email,
    'Planner email shoudld default to user email';
is $tag->format_planner, join(
    ' ',
    $sqitch->user_name,
    '<' . $sqitch->user_email . '>'
), 'Planner name and email should format properly';

my $ts = $tag->timestamp->as_string;
is $tag->as_string, "\@foo $ts ". $tag->format_planner,
    'Should as_string to "@foo" + timstamp + planner';
my $uri = URI->new('https://github.com/theory/sqitch/');
$mock_plan->mock( uri => $uri );
is $tag->info, join("\n",
    'project sql',
    'uri https://github.com/theory/sqitch/',
    'tag @foo',
    'change ' . $change->id,
    'planner ' . $tag->format_planner,
    'date '    . $ts,
), 'Tag info should incldue the URI';

my $date = App::Sqitch::DateTime->new(
    year   => 2012,
    month  => 7,
    day    => 16,
    hour   => 17,
    minute => 25,
    second => 7,
    time_zone => 'UTC',
);

ok $tag = $CLASS->new(
    name          => 'howdy',
    plan          => $plan,
    change        => $change,
    lspace        => '  ',
    rspace        => "\t",
    note          => 'blah blah blah',
    timestamp     => $date,
    planner_name  => 'Barack Obama',
    planner_email => 'potus@whitehouse.gov',
), 'Create tag with more stuff';

my $ts2 = '2012-07-16T17:25:07Z';
is $tag->as_string,
    "  \@howdy $ts2 Barack Obama <potus\@whitehouse.gov>\t# blah blah blah",
    'It should as_string correctly';

$mock_plan->mock(index_of => 1);
$mock_plan->mock(change_at => $change);
is $tag->change, $change, 'Change should be correct';
is $tag->format_planner, 'Barack Obama <potus@whitehouse.gov>',
    'Planner name and email should format properly';

# Make sure it gets the change even if there is a tag in between.
my @prevs = ($tag, $change);
$mock_plan->mock(index_of => 8);
$mock_plan->mock(change_at => sub { shift @prevs });
is $tag->change, $change, 'Change should be for previous change';

is $tag->info, join("\n",
    'project sql',
    'uri https://github.com/theory/sqitch/',
    'tag @howdy',
    'change ' . $change->id,
    'planner Barack Obama <potus@whitehouse.gov>',
    'date 2012-07-16T17:25:07Z'
), 'Tag info should include the change';

is $tag->id, do {
    my $content = $tag->info;
    Digest::SHA1->new->add(
        'tag ' . length($content) . "\0" . $content
    )->hexdigest;
},'Tag ID should be correct';

##############################################################################
# Test ID for a tag with a UTF-8 name.
ok $tag = $CLASS->new(
    name => '阱阪阬',
    plan => $plan,
    change  => $change,
), 'Create tag with UTF-8 name';
is $tag->info, join("\n",
    'project sql',
    'uri https://github.com/theory/sqitch/',
    'tag '     . '@阱阪阬',
    'change '  . $change->id,
    'planner ' . $tag->format_planner,
    'date '    . $tag->timestamp->as_string,
), 'The name should be decoded text';

is $tag->id, do {
    my $content = Encode::encode_utf8 $tag->info;
    Digest::SHA1->new->add(
        'tag ' . length($content) . "\0" . $content
    )->hexdigest;
},'Tag ID should be hahsed from encoded UTF-8';
