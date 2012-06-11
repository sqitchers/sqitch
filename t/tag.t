#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 11;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use Test::MockModule;
use Digest::SHA1;

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

my $sqitch = App::Sqitch->new;
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $tag = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
), $CLASS;
isa_ok $tag, 'App::Sqitch::Plan::Line';

is $tag->format_name, '@foo', 'Name should format as "@foo"';
is $tag->stringify, '@foo', 'Should stringify to "@foo"';

ok $tag = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    lspace  => '  ',
    rspace  => "\t",
    comment => ' blah blah blah',
), 'Create tag with more stuff';

is $tag->stringify, "  \@howdy\t# blah blah blah",
    'It should stringify correctly';

chdir 't';
my $mock_plan = Test::MockModule->new('App::Sqitch::Plan');
my $step = App::Sqitch::Plan::Step->new( plan => $plan, name => 'roles' );
$mock_plan->mock(index_of => 1);
$mock_plan->mock(node_at => $step);
is $tag->step_id, $step->id, 'Step ID should be correct';

is $tag->id, do {
    my $content = join "\n", (
        'object ' . $step->id,
        'type tag',
        'tag @howdy',
    );
    Digest::SHA1->new->add(
        'tag ' . length($content) . "\0" . $content
    )->hexdigest;
},'Tag SHA1 should be correct';


