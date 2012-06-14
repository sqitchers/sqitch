#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 86;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::Exception;
use App::Sqitch;
use App::Sqitch::Plan;
use URI;

BEGIN { require_ok 'App::Sqitch::Plan::NodeList' or die }

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);

my $foo = App::Sqitch::Plan::Step->new(plan => $plan, name => 'foo');
my $bar = App::Sqitch::Plan::Step->new(plan => $plan, name => 'bar');
my $baz = App::Sqitch::Plan::Step->new(plan => $plan, name => 'baz');
my $yo1 = App::Sqitch::Plan::Step->new(plan => $plan, name => 'yo');
my $yo2 = App::Sqitch::Plan::Step->new(plan => $plan, name => 'yo');

my $alpha = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    step => $yo1,
    name => 'alpha',
);
my $nodes = App::Sqitch::Plan::NodeList->new(
    $foo,
    $bar,
    $yo1,
    $alpha,
    $baz,
    $yo2,
);

is $nodes->count, 6, 'Count should be six';
is_deeply [$nodes->items], [$foo, $bar, $yo1, $alpha, $baz, $yo2],
    'Nodes should be in order';
is $nodes->item_at(0), $foo, 'Should have foo at 0';
is $nodes->item_at(1), $bar, 'Should have bar at 1';
is $nodes->item_at(2), $yo1, 'Should have yo1 at 2';
is $nodes->item_at(3), $alpha, 'Should have @alpha at 3';
is $nodes->item_at(4), $baz, 'Should have baz at 4';
is $nodes->item_at(5), $yo2, 'Should have yo2 at 5';

is $nodes->index_of('non'), undef, 'Should not find "non"';
is $nodes->index_of('@non'), undef, 'Should not find "@non"';
is $nodes->index_of('foo'), 0, 'Should find foo at 0';
is $nodes->index_of($foo->id), 0, 'Should find foo by ID at 0';
is $nodes->index_of('bar'), 1, 'Should find bar at 1';
is $nodes->index_of($bar->id), 1, 'Should find bar by ID at 1';
is $nodes->index_of('@alpha'), 3, 'Should find @alpha at 3';
is $nodes->index_of($alpha->id), 3, 'Should find @alpha by ID at 3';
is $nodes->index_of('baz'), 4, 'Should find baz at 4';
is $nodes->index_of($baz->id), 4, 'Should find baz by ID at 4';

throws_ok { $nodes->index_of('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $nodes->index_of('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

is $nodes->index_of('yo@alpha'), 2, 'Should get 2 for yo@alpha';
is $nodes->index_of('yo@HEAD'), 5, 'Should get 5 for yo@HEAD';
is $nodes->index_of('foo@alpha'), 0, 'Should get 0 for foo@alpha';
is $nodes->index_of('foo@HEAD'), 0, 'Should get 0 for foo@HEAD';
is $nodes->index_of('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $nodes->index_of('baz@HEAD'), 4, 'Should get 4 for baz@HEAD';

is $nodes->get('foo'), $foo, 'Should get foo for "foo"';
is $nodes->get($foo->id), $foo, 'Should get foo by ID';
is $nodes->get('bar'), $bar, 'Should get bar for "bar"';
is $nodes->get($bar->id), $bar, 'Should get bar by ID';
is $nodes->get($alpha->id), $alpha, 'Should get @alpha by ID';
is $nodes->get('baz'), $baz, 'Should get baz for "baz"';
is $nodes->get($baz->id), $baz, 'Should get baz by ID';

is $nodes->get('yo@alpha'), $yo1, 'Should get yo1 for yo@alpha';
is $nodes->get('yo@HEAD'), $yo2, 'Should get yo2 for yo@HEAD';
is $nodes->get('foo@alpha'), $foo, 'Should get foo for foo@alpha';
is $nodes->get('foo@HEAD'), $foo, 'Should get foo for foo@HEAD';
is $nodes->get('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $nodes->get('baz@HEAD'), $baz, 'Should get baz for baz@HEAD';

throws_ok { $nodes->get('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $nodes->get('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

my $hi = App::Sqitch::Plan::Step->new(plan => $plan, name => 'hi');
ok $nodes->append($hi), 'Push hi';
is $nodes->count, 7, 'Count should now be seven';
is_deeply [$nodes->items], [$foo, $bar, $yo1, $alpha, $baz, $yo2, $hi],
    'Nodes should be in order with $hi at the end';
is $nodes->index_of('hi'), 6, 'Should find "hi" at index 8';
is $nodes->index_of($hi->id), 6, 'Should find "hi" by ID at index 8';

# Now try first_index_of().
is $nodes->first_index_of('non'), undef, 'First index of "non" should be undef';
is $nodes->first_index_of('foo'), 0, 'First index of "foo" should be 0';
is $nodes->first_index_of('bar'), 1, 'First index of "bar" should be 1';
is $nodes->first_index_of('yo'), 2, 'First index of "yo" should be 2';
is $nodes->first_index_of('baz'), 4, 'First index of "baz" should be 4';
is $nodes->first_index_of('yo', '@alpha'), 5,
    'First index of "yo" since "@alpha" should be 5';
is $nodes->first_index_of('yo', 'baz'), 5,
    'First index of "yo" since "baz" should be 5';

# Try appending a couple more nodes.
my $so = App::Sqitch::Plan::Step->new(plan => $plan, name => 'so');
my $fu = App::Sqitch::Plan::Step->new(plan => $plan, name => 'fu');
ok $nodes->append($so, $fu), 'Push so and fu';
is $nodes->count, 9, 'Count should now be nine';
is_deeply [$nodes->items], [$foo, $bar, $yo1, $alpha, $baz, $yo2, $hi, $so, $fu],
    'Nodes should be in order with $so and $fu at the end';

##############################################################################
# Test last_tag(), last_step, index_of_last_tag(), and index_of_last_step().
is $nodes->index_of_last_tag, 3, 'Should get 3 for last tag index';
is $nodes->last_tag, $alpha, 'Should find @alpha as last tag';
is $nodes->index_of_last_step, 8, 'Should get 8 for last step index';
is $nodes->last_step, $fu, 'Should find fu as last step';

for my $nodes (
    [0, $alpha],
    [1, $foo, $alpha],
    [4, $foo, $alpha, $bar, $baz, $alpha, $yo1],
    [6, $foo, $alpha, $bar, $baz, $alpha, $yo1, $alpha],
) {
    my $tag_index = shift @{ $nodes };
    my $step_index = $tag_index == $#$nodes ? $#$nodes - 1 : $#$nodes;
    my $n = App::Sqitch::Plan::NodeList->new(@{ $nodes });
    is $n->index_of_last_tag, $tag_index, "Should find last tag index at $tag_index";
    is $n->last_tag, $nodes->[$tag_index], "Should find last tag at $tag_index";
    if ($tag_index) {
        is $n->index_of_last_step, $step_index, "Should find last step index at $step_index";
        is $n->last_step, $nodes->[$step_index], "Should find last step at $step_index";
    } else {
        is $n->index_of_last_step, undef, "Should no step index";
        is $n->last_step, undef, "Should find no step";
    }
}

for my $nodes (
    [],
    [$foo, $baz],
    [$foo, $bar, $baz, $yo1, $yo2],
) {
    my $n = App::Sqitch::Plan::NodeList->new(@{ $nodes });
    is $n->index_of_last_tag, undef,
        'Should not find tag index in ' . scalar @{$nodes} . ' nodes';
    is $n->last_tag, undef,
        'Should not find tag in ' . scalar @{$nodes} . ' nodes';
    if (!@{ $nodes }) {
        is $n->index_of_last_step, undef, "Should no step index in empty plan";
        is $n->last_step, undef, "Should find no step in empty plan";
    }
}
