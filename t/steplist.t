#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 108;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::Exception;
use App::Sqitch;
use App::Sqitch::Plan;
use URI;

BEGIN { require_ok 'App::Sqitch::Plan::StepList' or die }

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
$yo1->add_tag($alpha);
my $steps = App::Sqitch::Plan::StepList->new(
    $foo,
    $bar,
    $yo1,
    $baz,
    $yo2,
);

is $steps->count, 5, 'Count should be six';
is_deeply [$steps->steps], [$foo, $bar, $yo1, $baz, $yo2],
    'Steps should be in order';
is_deeply [$steps->items], [$steps->steps],
    'Items should be the same as steps';
is $steps->step_at(0), $foo, 'Should have foo at 0';
is $steps->step_at(1), $bar, 'Should have bar at 1';
is $steps->step_at(2), $yo1, 'Should have yo1 at 2';
is $steps->step_at(3), $baz, 'Should have baz at 4';
is $steps->step_at(4), $yo2, 'Should have yo2 at 5';

is $steps->index_of('non'), undef, 'Should not find "non"';
is $steps->index_of('@non'), undef, 'Should not find "@non"';
is $steps->index_of('foo'), 0, 'Should find foo at 0';
is $steps->index_of($foo->id), 0, 'Should find foo by ID at 0';
is $steps->index_of('bar'), 1, 'Should find bar at 1';
is $steps->index_of($bar->id), 1, 'Should find bar by ID at 1';
is $steps->index_of('@alpha'), 2, 'Should find @alpha at 2';
is $steps->index_of($alpha->id), 2, 'Should find @alpha by ID at 2';
is $steps->index_of('baz'), 3, 'Should find baz at 3';
is $steps->index_of($baz->id), 3, 'Should find baz by ID at 3';

throws_ok { $steps->index_of('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $steps->index_of('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

is $steps->index_of('yo@alpha'), 2, 'Should get 2 for yo@alpha';
is $steps->index_of('yo@HEAD'), 4, 'Should get 4 for yo@HEAD';
is $steps->index_of('foo@alpha'), 0, 'Should get 0 for foo@alpha';
is $steps->index_of('foo@HEAD'), 0, 'Should get 0 for foo@HEAD';
is $steps->index_of('foo@ROOT'), 0, 'Should get 0 for foo@ROOT';
is $steps->index_of('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $steps->index_of('baz@HEAD'), 3, 'Should get 3 for baz@HEAD';
is $steps->index_of('@HEAD'), 4, 'Should get 4 for @HEAD';
is $steps->index_of('@ROOT'), 0, 'Should get 0 for @ROOT';

is $steps->get('foo'), $foo, 'Should get foo for "foo"';
is $steps->get($foo->id), $foo, 'Should get foo by ID';
is $steps->get('bar'), $bar, 'Should get bar for "bar"';
is $steps->get($bar->id), $bar, 'Should get bar by ID';
is $steps->get($alpha->id), $yo1, 'Should get "yo" by the @alpha tag';
is $steps->get('baz'), $baz, 'Should get baz for "baz"';
is $steps->get($baz->id), $baz, 'Should get baz by ID';
is $steps->get('@HEAD'), $yo2, 'Should get yo2 for "@HEAD"';
is $steps->get('@ROOT'), $foo, 'Should get foo for "@ROOT"';

is $steps->get('yo@alpha'), $yo1, 'Should get yo1 for yo@alpha';
is $steps->get('yo@HEAD'), $yo2, 'Should get yo2 for yo@HEAD';
is $steps->get('foo@alpha'), $foo, 'Should get foo for foo@alpha';
is $steps->get('foo@HEAD'), $foo, 'Should get foo for foo@HEAD';
is $steps->get('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $steps->get('baz@HEAD'), $baz, 'Should get baz for baz@HEAD';
is $steps->get('yo@HEAD'), $yo2, 'Should get yo2 for "yo@HEAD"';
is $steps->get('foo@ROOT'), $foo, 'Should get foo for "foo@ROOT"';

is $steps->find('yo'), $yo1, 'Should find yo1 with "yo"';
is $steps->find('yo@alpha'), $yo1, 'Should find yo1 with "yo@alpha"';
is $steps->find('yo@HEAD'), $yo2, 'Should find yo2 with yo@HEAD';
is $steps->find('foo'), $foo, 'Should find foo for "foo"';
is $steps->find('foo@alpha'), $foo, 'Should find foo for "foo@alpha"';
is $steps->find('foo@HEAD'), $foo, 'Should find foo for "foo@HEAD"';

throws_ok { $steps->get('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $steps->get('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

my $hi = App::Sqitch::Plan::Step->new(plan => $plan, name => 'hi');
ok $steps->append($hi), 'Push hi';
is $steps->count, 6, 'Count should now be six';
is_deeply [$steps->steps], [$foo, $bar, $yo1, $baz, $yo2, $hi],
    'Steps should be in order with $hi at the end';
is $steps->index_of('hi'), 5, 'Should find "hi" at index 5';
is $steps->index_of($hi->id), 5, 'Should find "hi" by ID at index 5';
is $steps->index_of('@ROOT'), 0, 'Index of @ROOT should still be 0';
is $steps->index_of('@HEAD'), 5, 'Index of @HEAD should now be 5';

# Now try first_index_of().
is $steps->first_index_of('non'), undef, 'First index of "non" should be undef';
is $steps->first_index_of('foo'), 0, 'First index of "foo" should be 0';
is $steps->first_index_of('foo', '@ROOT'), undef, 'First index of "foo" since @ROOT should be undef';
is $steps->first_index_of('bar'), 1, 'First index of "bar" should be 1';
is $steps->first_index_of('yo'), 2, 'First index of "yo" should be 2';
is $steps->first_index_of('yo', '@ROOT'), 2, 'First index of "yo" since @ROOT should be 2';
is $steps->first_index_of('baz'), 3, 'First index of "baz" should be 3';
is $steps->first_index_of('yo', '@alpha'), 4,
    'First index of "yo" since "@alpha" should be 4';
is $steps->first_index_of('yo', 'baz'), 4,
    'First index of "yo" since "baz" should be 3';

# Try appending a couple more steps.
my $so = App::Sqitch::Plan::Step->new(plan => $plan, name => 'so');
my $fu = App::Sqitch::Plan::Step->new(plan => $plan, name => 'fu');
ok $steps->append($so, $fu), 'Push so and fu';
is $steps->count, 8, 'Count should now be eight';
is $steps->index_of('@ROOT'), 0, 'Index of @ROOT should remain 0';
is $steps->index_of('@HEAD'), 7, 'Index of @HEAD should now be 7';
is_deeply [$steps->steps], [$foo, $bar, $yo1, $baz, $yo2, $hi, $so, $fu],
    'Steps should be in order with $so and $fu at the end';

# Try indexing a tag.
my $beta = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    step => $yo2,
    name => 'beta',
);
$yo2->add_tag($beta);
ok $steps->index_tag(4, $beta), 'Index beta';
is $steps->index_of('@beta'), 4, 'Should find @beta at index 4';
is $steps->get('@beta'), $yo2, 'Should find yo2 via @beta';
is $steps->get($beta->id), $yo2, 'Should find yo2 via @beta ID';

##############################################################################
# Test last_tagged(), last_step(), index_of_last_tagged().
is $steps->index_of_last_tagged, 2, 'Should get 2 for last tagged index';
is $steps->last_tagged_step, $yo1, 'Should find "yo" as last tagged';
is $steps->count, 8, 'Should get 8 for count';
is $steps->last_step, $fu, 'Should find fu as last step';

for my $steps (
    [0, $yo1],
    [1, $foo, $yo1],
    [3, $foo, $bar, $baz, $yo1],
    [4, $foo, $bar, $baz, $hi, $yo1],
) {
    my $index = shift @{ $steps };
    my $n = App::Sqitch::Plan::StepList->new(@{ $steps });
    is $n->index_of_last_tagged, $index, "Should find last tagged index at $index";
    is $n->last_tagged_step, $steps->[$index], "Should find last tagged at $index";
    is $n->count, ($index + 1), "Should get count " . ($index + 1);
    is $n->last_step, $steps->[$index], "Should find last step at $index";
}

for my $steps (
    [],
    [$foo, $baz],
    [$foo, $bar, $baz, $hi],
) {
    my $n = App::Sqitch::Plan::StepList->new(@{ $steps });
    is $n->index_of_last_tagged, undef,
        'Should not find tag index in ' . scalar @{$steps} . ' steps';
    is $n->last_tagged_step, undef,
        'Should not find tag in ' . scalar @{$steps} . ' steps';
    if (!@{ $steps }) {
        is $n->last_step, undef, "Should find no step in empty plan";
    }
}
