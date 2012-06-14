#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 14;
#use Test::More 'no_plan';
use Test::NoWarnings;
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
    comment
    plan
);

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
my $step = App::Sqitch::Plan::Step->new( plan => $plan, name => 'roles' );

isa_ok my $tag = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
    step  => $step,
), $CLASS;
isa_ok $tag, 'App::Sqitch::Plan::Line';
my $mock_plan = Test::MockModule->new('App::Sqitch::Plan');
$mock_plan->mock(index_of => 0); # no other nodes

is $tag->format_name, '@foo', 'Name should format as "@foo"';
is $tag->as_string, '@foo', 'Should as_string to "@foo"';
is $tag->info, join("\n",
    'project ' . $sqitch->uri->canonical,
    'tag @foo',
    'step ' . $step->id,
), 'Tag info should be correct';

ok $tag = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    step    => $step,
    lspace  => '  ',
    rspace  => "\t",
    comment => ' blah blah blah',
), 'Create tag with more stuff';

is $tag->as_string, "  \@howdy\t# blah blah blah",
    'It should as_string correctly';

$mock_plan->mock(index_of => 1);
$mock_plan->mock(node_at => $step);
is $tag->step, $step, 'Step should be correct';

# Make sure it gets the step even if there is a tag in between.
my @prevs = ($tag, $step);
$mock_plan->mock(index_of => 8);
$mock_plan->mock(node_at => sub { shift @prevs });
is $tag->step, $step, 'Step should be for previous step';

is $tag->info, join("\n",
    'project ' . $sqitch->uri->canonical,
    'tag @howdy',
    'step ' . $step->id,
), 'Tag info should include the step';

is $tag->id, do {
    my $content = $tag->info;
    Digest::SHA1->new->add(
        'tag ' . length($content) . "\0" . $content
    )->hexdigest;
},'Tag ID should be correct';
