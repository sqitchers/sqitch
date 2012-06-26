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

BEGIN { require_ok 'App::Sqitch::Plan::ChangeList' or die }

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);

my $foo = App::Sqitch::Plan::Change->new(plan => $plan, name => 'foo');
my $bar = App::Sqitch::Plan::Change->new(plan => $plan, name => 'bar');
my $baz = App::Sqitch::Plan::Change->new(plan => $plan, name => 'baz');
my $yo1 = App::Sqitch::Plan::Change->new(plan => $plan, name => 'yo');
my $yo2 = App::Sqitch::Plan::Change->new(plan => $plan, name => 'yo');

my $alpha = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    change => $yo1,
    name => 'alpha',
);
$yo1->add_tag($alpha);
my $changes = App::Sqitch::Plan::ChangeList->new(
    $foo,
    $bar,
    $yo1,
    $baz,
    $yo2,
);

is $changes->count, 5, 'Count should be six';
is_deeply [$changes->changes], [$foo, $bar, $yo1, $baz, $yo2],
    'Changes should be in order';
is_deeply [$changes->items], [$changes->changes],
    'Items should be the same as changes';
is $changes->change_at(0), $foo, 'Should have foo at 0';
is $changes->change_at(1), $bar, 'Should have bar at 1';
is $changes->change_at(2), $yo1, 'Should have yo1 at 2';
is $changes->change_at(3), $baz, 'Should have baz at 4';
is $changes->change_at(4), $yo2, 'Should have yo2 at 5';

is $changes->index_of('non'), undef, 'Should not find "non"';
is $changes->index_of('@non'), undef, 'Should not find "@non"';
is $changes->index_of('foo'), 0, 'Should find foo at 0';
is $changes->index_of($foo->id), 0, 'Should find foo by ID at 0';
is $changes->index_of('bar'), 1, 'Should find bar at 1';
is $changes->index_of($bar->id), 1, 'Should find bar by ID at 1';
is $changes->index_of('@alpha'), 2, 'Should find @alpha at 2';
is $changes->index_of($alpha->id), 2, 'Should find @alpha by ID at 2';
is $changes->index_of('baz'), 3, 'Should find baz at 3';
is $changes->index_of($baz->id), 3, 'Should find baz by ID at 3';

throws_ok { $changes->index_of('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $changes->index_of('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

is $changes->index_of('yo@alpha'), 2, 'Should get 2 for yo@alpha';
is $changes->index_of('yo@HEAD'), 4, 'Should get 4 for yo@HEAD';
is $changes->index_of('foo@alpha'), 0, 'Should get 0 for foo@alpha';
is $changes->index_of('foo@HEAD'), 0, 'Should get 0 for foo@HEAD';
is $changes->index_of('foo@ROOT'), 0, 'Should get 0 for foo@ROOT';
is $changes->index_of('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $changes->index_of('baz@HEAD'), 3, 'Should get 3 for baz@HEAD';
is $changes->index_of('@HEAD'), 4, 'Should get 4 for @HEAD';
is $changes->index_of('@ROOT'), 0, 'Should get 0 for @ROOT';

is $changes->get('foo'), $foo, 'Should get foo for "foo"';
is $changes->get($foo->id), $foo, 'Should get foo by ID';
is $changes->get('bar'), $bar, 'Should get bar for "bar"';
is $changes->get($bar->id), $bar, 'Should get bar by ID';
is $changes->get($alpha->id), $yo1, 'Should get "yo" by the @alpha tag';
is $changes->get('baz'), $baz, 'Should get baz for "baz"';
is $changes->get($baz->id), $baz, 'Should get baz by ID';
is $changes->get('@HEAD'), $yo2, 'Should get yo2 for "@HEAD"';
is $changes->get('@ROOT'), $foo, 'Should get foo for "@ROOT"';

is $changes->get('yo@alpha'), $yo1, 'Should get yo1 for yo@alpha';
is $changes->get('yo@HEAD'), $yo2, 'Should get yo2 for yo@HEAD';
is $changes->get('foo@alpha'), $foo, 'Should get foo for foo@alpha';
is $changes->get('foo@HEAD'), $foo, 'Should get foo for foo@HEAD';
is $changes->get('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $changes->get('baz@HEAD'), $baz, 'Should get baz for baz@HEAD';
is $changes->get('yo@HEAD'), $yo2, 'Should get yo2 for "yo@HEAD"';
is $changes->get('foo@ROOT'), $foo, 'Should get foo for "foo@ROOT"';

is $changes->find('yo'), $yo1, 'Should find yo1 with "yo"';
is $changes->find('yo@alpha'), $yo1, 'Should find yo1 with "yo@alpha"';
is $changes->find('yo@HEAD'), $yo2, 'Should find yo2 with yo@HEAD';
is $changes->find('foo'), $foo, 'Should find foo for "foo"';
is $changes->find('foo@alpha'), $foo, 'Should find foo for "foo@alpha"';
is $changes->find('foo@HEAD'), $foo, 'Should find foo for "foo@HEAD"';

throws_ok { $changes->get('yo') } qr/^\QKey "yo" at multiple indexes/,
    'Should get error looking for index of "yo"';

throws_ok { $changes->get('yo@howdy') } qr/^\QUnknown tag: "howdy"/,
    'Should get error looking for invalid tag';

my $hi = App::Sqitch::Plan::Change->new(plan => $plan, name => 'hi');
ok $changes->append($hi), 'Push hi';
is $changes->count, 6, 'Count should now be six';
is_deeply [$changes->changes], [$foo, $bar, $yo1, $baz, $yo2, $hi],
    'Changes should be in order with $hi at the end';
is $changes->index_of('hi'), 5, 'Should find "hi" at index 5';
is $changes->index_of($hi->id), 5, 'Should find "hi" by ID at index 5';
is $changes->index_of('@ROOT'), 0, 'Index of @ROOT should still be 0';
is $changes->index_of('@HEAD'), 5, 'Index of @HEAD should now be 5';

# Now try first_index_of().
is $changes->first_index_of('non'), undef, 'First index of "non" should be undef';
is $changes->first_index_of('foo'), 0, 'First index of "foo" should be 0';
is $changes->first_index_of('foo', '@ROOT'), undef, 'First index of "foo" since @ROOT should be undef';
is $changes->first_index_of('bar'), 1, 'First index of "bar" should be 1';
is $changes->first_index_of('yo'), 2, 'First index of "yo" should be 2';
is $changes->first_index_of('yo', '@ROOT'), 2, 'First index of "yo" since @ROOT should be 2';
is $changes->first_index_of('baz'), 3, 'First index of "baz" should be 3';
is $changes->first_index_of('yo', '@alpha'), 4,
    'First index of "yo" since "@alpha" should be 4';
is $changes->first_index_of('yo', 'baz'), 4,
    'First index of "yo" since "baz" should be 3';

# Try appending a couple more changes.
my $so = App::Sqitch::Plan::Change->new(plan => $plan, name => 'so');
my $fu = App::Sqitch::Plan::Change->new(plan => $plan, name => 'fu');
ok $changes->append($so, $fu), 'Push so and fu';
is $changes->count, 8, 'Count should now be eight';
is $changes->index_of('@ROOT'), 0, 'Index of @ROOT should remain 0';
is $changes->index_of('@HEAD'), 7, 'Index of @HEAD should now be 7';
is_deeply [$changes->changes], [$foo, $bar, $yo1, $baz, $yo2, $hi, $so, $fu],
    'Changes should be in order with $so and $fu at the end';

# Try indexing a tag.
my $beta = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    change => $yo2,
    name => 'beta',
);
$yo2->add_tag($beta);
ok $changes->index_tag(4, $beta), 'Index beta';
is $changes->index_of('@beta'), 4, 'Should find @beta at index 4';
is $changes->get('@beta'), $yo2, 'Should find yo2 via @beta';
is $changes->get($beta->id), $yo2, 'Should find yo2 via @beta ID';

##############################################################################
# Test last_tagged(), last_change(), index_of_last_tagged().
is $changes->index_of_last_tagged, 2, 'Should get 2 for last tagged index';
is $changes->last_tagged_change, $yo1, 'Should find "yo" as last tagged';
is $changes->count, 8, 'Should get 8 for count';
is $changes->last_change, $fu, 'Should find fu as last change';

for my $changes (
    [0, $yo1],
    [1, $foo, $yo1],
    [3, $foo, $bar, $baz, $yo1],
    [4, $foo, $bar, $baz, $hi, $yo1],
) {
    my $index = shift @{ $changes };
    my $n = App::Sqitch::Plan::ChangeList->new(@{ $changes });
    is $n->index_of_last_tagged, $index, "Should find last tagged index at $index";
    is $n->last_tagged_change, $changes->[$index], "Should find last tagged at $index";
    is $n->count, ($index + 1), "Should get count " . ($index + 1);
    is $n->last_change, $changes->[$index], "Should find last change at $index";
}

for my $changes (
    [],
    [$foo, $baz],
    [$foo, $bar, $baz, $hi],
) {
    my $n = App::Sqitch::Plan::ChangeList->new(@{ $changes });
    is $n->index_of_last_tagged, undef,
        'Should not find tag index in ' . scalar @{$changes} . ' changes';
    is $n->last_tagged_change, undef,
        'Should not find tag in ' . scalar @{$changes} . ' changes';
    if (!@{ $changes }) {
        is $n->last_change, undef, "Should find no change in empty plan";
    }
}
