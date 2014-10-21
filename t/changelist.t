#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 351;
#use Test::More 'no_plan';
use Test::NoWarnings;
use Test::Exception;
use Path::Class;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use Locale::TextDomain qw(App-Sqitch);
use Test::MockModule;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

BEGIN { require_ok 'App::Sqitch::Plan::ChangeList' or die }

my $sqitch = App::Sqitch->new(options => {
    engine => 'sqlite',
    top_dir => dir(qw(t sql))->stringify,
});
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target);

my $foo = App::Sqitch::Plan::Change->new(plan => $plan, name => 'foo');
my $bar = App::Sqitch::Plan::Change->new(plan => $plan, name => 'bar', parent => $foo);
my $baz = App::Sqitch::Plan::Change->new(plan => $plan, name => 'baz', parent => $bar);
my $yo1 = App::Sqitch::Plan::Change->new(plan => $plan, name => 'yo', parent => $baz);
my $yo2 = App::Sqitch::Plan::Change->new(plan => $plan, name => 'yo', parent => $yo1, planner_name => 'Phil' );

my $alpha = App::Sqitch::Plan::Tag->new(
    plan   => $plan,
    change => $yo1,
    name   => 'alpha',
);
$yo1->add_tag($alpha);
my $changes = App::Sqitch::Plan::ChangeList->new(
    $foo,
    $bar,
    $yo1,
    $baz,
    $yo2,
);

my ($earliest_id, $latest_id);
my $engine_mocker = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my $offset = 0;

$engine_mocker->mock(earliest_change_id => sub {
     $offset = $_[1];
     $changes->change_at( $changes->index_of($earliest_id) + $offset )->id;
});

$engine_mocker->mock(latest_change_id => sub {
    $offset = $_[1];
    $changes->change_at( $changes->index_of($latest_id) - $offset )->id;
});

is $changes->count, 5, 'Count should be six';
is_deeply [$changes->changes], [$foo, $bar, $yo1, $baz, $yo2],
    'Changes should be in order';
is_deeply [$changes->items], [$changes->changes],
    'Items should be the same as changes';
is_deeply [$changes->tags], [$alpha], 'Tags should return the one tag';
is $changes->change_at(0), $foo, 'Should have foo at 0';
is $changes->change_at(1), $bar, 'Should have bar at 1';
is $changes->change_at(2), $yo1, 'Should have yo1 at 2';
is $changes->change_at(3), $baz, 'Should have baz at 4';
is $changes->change_at(4), $yo2, 'Should have yo2 at 5';

is $changes->index_of('non'), undef, 'Should not find "non"';
is $changes->index_of('@non'), undef, 'Should not find "@non"';
is $changes->index_of('foo'), 0, 'Should find foo at 0';
is $changes->index_of($foo->id), 0, 'Should find foo by ID at 0';
is $changes->index_of($foo->old_id), 0, 'Should find foo by old ID at 0';
is $changes->index_of('bar'), 1, 'Should find bar at 1';
is $changes->index_of('bar^'), 0, 'Should find bar^ at 0';
is $changes->index_of('bar~'), 2, 'Should find bar~ at 2';
is $changes->index_of('bar~~'), 3, 'Should find bar~~ at 3';
is $changes->index_of('bar~~~'), undef, 'Should not find bar~~~';
is $changes->index_of('bar~2'), 3, 'Should find bar~2 at 3';
is $changes->index_of('bar~3'), 4, 'Should find bar~3 at 4';
is $changes->index_of($bar->id), 1, 'Should find bar by ID at 1';
is $changes->index_of($bar->old_id), 1, 'Should find bar by old ID at 1';
is $changes->index_of('@alpha'), 2, 'Should find @alpha at 2';
is $changes->index_of('@alpha^'), 1, 'Should find @alpha^ at 1';
is $changes->index_of('@alpha^^'), 0, 'Should find @alpha^^ at 1';
is $changes->index_of('@alpha^^^'), undef, 'Should not find @alpha^^^';
is $changes->index_of($alpha->id), 2, 'Should find @alpha by ID at 2';
is $changes->index_of($alpha->old_id), 2, 'Should find @alpha by old ID at 2';
is $changes->index_of('baz'), 3, 'Should find baz at 3';
is $changes->index_of($baz->id), 3, 'Should find baz by ID at 3';
is $changes->index_of($baz->old_id), 3, 'Should find baz by old ID at 3';
is $changes->index_of('baz^^^'), undef, 'Should not find baz^^^';
is $changes->index_of('baz^3'), 0, 'Should not find baz^3 at 0';
is $changes->index_of('baz^4'), undef, 'Should not find baz^4';
is $changes->index_of($baz->id . '^'), 2, 'Should find baz by ID^ at 2';
is $changes->index_of($baz->old_id . '^'), 2, 'Should find baz by old ID^ at 2';

# Test @FIRST.
$earliest_id = $bar->id;
is $changes->index_of('@FIRST'), 1, 'Should find @FIRST at 1';
is $offset, 0, 'Should have no offset for @FIRST';
$offset = undef;
is $changes->index_of('@FIRST^'), undef, 'Should find undef for @FIRST^';
is $offset, undef, 'Offset should not be set';
is $changes->index_of('@FIRST~'), 2, 'Should find @FIRST~ at 2';
is $offset, 1, 'Should have offset 1 for @FIRST~';
is $changes->index_of('@FIRST~~'), 3, 'Should find @FIRST~~ at 3';
is $offset, 2, 'Should have offset 2 for @FIRST~';
$offset = undef;
is $changes->index_of('@FIRST~~~'), undef, 'Should not find @FIRST~~~';
is $offset, undef, 'Offset should not be set';
is $changes->index_of('@FIRST~2'), 3, 'Should find @FIRST~2 at 3';
is $offset, 2, 'Should have offset 2 for @FIRST~2';
is $changes->index_of('@FIRST~3'), 4, 'Should find @FIRST~3 at 4';
is $offset, 3, 'Should have offset 3 for @FIRST~3';

is $changes->first_index_of('@FIRST'), 1, 'Should find @FIRST at 1';
is $offset, 0, 'Should have no offset for @FIRST';
$offset = undef;
is $changes->first_index_of('@FIRST^'), undef, 'Should find undef for @FIRST^';
is $offset, undef, 'Offset should not be set';
is $changes->first_index_of('@FIRST~'), 2, 'Should find @FIRST~ at 2';
is $offset, 1, 'Should have offset 1 for @FIRST~';
is $changes->first_index_of('@FIRST~~'), 3, 'Should find @FIRST~~ at 3';
is $offset, 2, 'Should have offset 2 for @FIRST~';
$offset = undef;
is $changes->first_index_of('@FIRST~~~'), undef, 'Should not find @FIRST~~~';
is $offset, undef, 'Offset should not be set';
is $changes->first_index_of('@FIRST~2'), 3, 'Should find @FIRST~2 at 3';
is $offset, 2, 'Should have offset 2 for @FIRST~2';
is $changes->first_index_of('@FIRST~3'), 4, 'Should find @FIRST~3 at 4';
is $offset, 3, 'Should have offset 3 for @FIRST~3';

is $changes->get('@FIRST'), $bar, 'Should get bar for @FIRST';
is $offset, 0, 'Should have no offset for @FIRST';
$offset = undef;
is $changes->get('@FIRST^'), undef, 'Should get nothing for @FIRST^';
is $offset, undef, 'Offset should not be set';
is $changes->get('@FIRST~'), $yo1, 'Should get yo1 for @FIRST~';
is $offset, 1, 'Should have offset 1 for @FIRST~';

ok $changes->contains('@FIRST'), 'Should contain @FIRST';
is $changes->find('@FIRST'), $bar, 'Should find bar for @FIRST';
is $offset, 0, 'Should have no offset for @FIRST';
$offset = undef;
ok !$changes->contains('@FIRST^'), 'Should not contain @FIRST^';
is $changes->find('@FIRST^'), undef, 'Should find nothing for @FIRST^';
is $offset, undef, 'Offset should not be set';
ok $changes->contains('@FIRST~'), 'Should contain @FIRST~';
is $changes->find('@FIRST~'), $yo1, 'Should find yo1 for @FIRST~';
is $offset, 1, 'Should have offset 1 for @FIRST~';
$earliest_id = undef;

# Test @LAST.
$latest_id = $yo1->id;
$offset = undef;
is $changes->index_of('@LAST'), 2, 'Should find @LAST at 2';
is $offset, 0, 'Should have offset 0 for @LAST';
is $changes->index_of('@LAST^'), 1, 'Should find @LAST^ at 1';
is $offset, 1, 'Should have offset 1 for @LAST^';
is $changes->index_of('@LAST^^'), 0, 'Should find @LAST^^ at 1';
is $offset, 2, 'Should have offset 2 for @LAST^^';
$offset = undef;
is $changes->index_of('@LAST^^^'), undef, 'Should not find @LAST^^^';
is $offset, undef, 'Offset should not be set';

is $changes->first_index_of('@LAST'), 2, 'Should find @LAST at 2';
is $offset, 0, 'Should have offset 0 for @LAST';
is $changes->first_index_of('@LAST^'), 1, 'Should find @LAST^ at 1';
is $offset, 1, 'Should have offset 1 for @LAST^';
is $changes->first_index_of('@LAST^^'), 0, 'Should find @LAST^^ at 1';
is $offset, 2, 'Should have offset 2 for @LAST^^';
$offset = undef;
is $changes->first_index_of('@LAST^^^'), undef, 'Should not find @LAST^^^';
is $offset, undef, 'Offset should not be set';

is $changes->get('@LAST'), $yo1, 'Should get yo1 for @LAST';
is $offset, 0, 'Should have offset 0 for @LAST';
is $changes->get('@LAST^'), $bar, 'should get bar for @LAST^';
is $offset, 1, 'Should have offset 1 for @LAST^';
$offset = undef;
is $changes->get('@LAST~'), undef, 'should get nothing for @LAST~';
is $offset, undef, 'Offset should not be set';

ok $changes->contains('@LAST'), 'Should contain @LAST';
is $changes->find('@LAST'), $yo1, 'Should find yo1 for @LAST';
is $offset, 0, 'Should have offset 0 for @LAST';
ok $changes->contains('@LAST^'), 'Should contain @LAST^';
is $changes->find('@LAST^'), $bar, 'should find bar for @LAST^';
is $offset, 1, 'Should have offset 1 for @LAST^';
$offset = undef;
ok !$changes->contains('@LAST~'), 'Should not contain @LAST~';
is $changes->find('@LAST~'), undef, 'should find nothing for @LAST~';
is $offset, undef, 'Offset should not be set';
$latest_id = undef;

throws_ok { $changes->index_of('yo') } 'App::Sqitch::X',
    'Should get multiple indexes error looking for index of "yo"';
is $@->ident, 'plan', 'Multiple indexes error ident should be "plan"';
is $@->message, __x(
    'Key {key} at multiple indexes',
    key => 'yo',
), 'Multiple indexes message should be correct';

throws_ok { $changes->index_of('yo@howdy') } 'App::Sqitch::X',
    'Should unknown tag error for invalid tag';
is $@->ident, 'plan', 'Unknown tag error ident should be "plan"';
is $@->message, __x(
    'Unknown tag "{tag}"',
    tag => '@howdy',
), 'Unknown taf message should be correct';

is $changes->index_of('yo@alpha'), 2, 'Should get 2 for yo@alpha';
is $changes->index_of('yo@alpha^'), 1, 'Should get 1 for yo@alpha^';
is $changes->index_of('yo@HEAD'), 4, 'Should get 4 for yo@HEAD';
is $changes->index_of('yo@HEAD^'), 3, 'Should get 3 for yo@HEAD^';
is $changes->index_of('yo@HEAD~'), undef, 'Should get undef for yo@HEAD~';
is $changes->index_of('yo@HEAD~~'), undef, 'Should get undef for yo@HEAD~~';
is $changes->index_of('foo@alpha'), 0, 'Should get 0 for foo@alpha';
is $changes->index_of('foo@HEAD'), 0, 'Should get 0 for foo@HEAD';
is $changes->index_of('foo@ROOT'), 0, 'Should get 0 for foo@ROOT';
is $changes->index_of('baz@alpha'), undef, 'Should get undef for baz@alpha';
is $changes->index_of('baz@HEAD'), 3, 'Should get 3 for baz@HEAD';
is $changes->index_of('@HEAD'), 4, 'Should get 4 for @HEAD';
is $changes->index_of('@ROOT'), 0, 'Should get 0 for @ROOT';
is $changes->index_of('@HEAD^'), 3, 'Should get 3 for @HEAD^';
is $changes->index_of('@HEAD~'), undef, 'Should get undef for @HEAD~';
is $changes->index_of('@ROOT~'), 1, 'Should get 1 for @ROOT~';
is $changes->index_of('@ROOT^'), undef, 'Should get undef for @ROOT^';
is $changes->index_of('HEAD'), 4, 'Should get 4 for HEAD';
is $changes->index_of('ROOT'), 0, 'Should get 0 for ROOT';
is $changes->index_of('HEAD^'), 3, 'Should get 3 for HEAD^';
is $changes->index_of('HEAD~'), undef, 'Should get undef for HEAD~';
is $changes->index_of('ROOT~'), 1, 'Should get 1 for ROOT~';
is $changes->index_of('ROOT^'), undef, 'Should get undef for ROOT^';

is $changes->get('foo'), $foo, 'Should get foo for "foo"';
is $changes->get('foo~'), $bar, 'Should get bar for "foo~"';
is $changes->get($foo->id), $foo, 'Should get foo by ID';
is $changes->get($foo->old_id), $foo, 'Should get foo by old ID';
is $changes->get('bar'), $bar, 'Should get bar for "bar"';
is $changes->get('bar^'), $foo, 'Should get foo for "bar^"';
is $changes->get('bar~'), $yo1, 'Should get yo1 for "bar~"';
is $changes->get('bar~~'), $baz, 'Should get baz for "bar~~"';
is $changes->get('bar~3'), $yo2, 'Should get yo2 for "bar~3"';
is $changes->get($bar->id), $bar, 'Should get bar by ID';
is $changes->get($bar->old_id), $bar, 'Should get bar by old ID';
is $changes->get($alpha->id), $yo1, 'Should get "yo" by the @alpha tag ID';
is $changes->get($alpha->old_id), $yo1, 'Should get "yo" by the @alpha tag old ID';
is $changes->get('baz'), $baz, 'Should get baz for "baz"';
is $changes->get($baz->id), $baz, 'Should get baz by ID';
is $changes->get($baz->old_id), $baz, 'Should get baz by old ID';
is $changes->get('@HEAD^'), $baz, 'Should get baz for "@HEAD^"';
is $changes->get('@HEAD^^'), $yo1, 'Should get yo1 for "@HEAD^^"';
is $changes->get('@HEAD^3'), $bar, 'Should get bar for "@HEAD^3"';
is $changes->get('@ROOT'), $foo, 'Should get foo for "@ROOT"';
is $changes->get('HEAD^'), $baz, 'Should get baz for "HEAD^"';
is $changes->get('HEAD^^'), $yo1, 'Should get yo1 for "HEAD^^"';
is $changes->get('HEAD^3'), $bar, 'Should get bar for "HEAD^3"';
is $changes->get('ROOT'), $foo, 'Should get foo for "ROOT"';

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
is $changes->find('yo^'), $bar, 'Should find bar with "yo^"';
is $changes->find('yo^^'), $foo, 'Should find foo with "yo^^"';
is $changes->find('yo^2'), $foo, 'Should find foo with "yo^2"';
is $changes->find('yo~'), $baz, 'Should find baz with "yo~"';
is $changes->find('yo~~'), $yo2, 'Should find yo2 with "yo~~"';
is $changes->find('yo~2'), $yo2, 'Should find yo2 with "yo~2"';
is $changes->find('yo@alpha^'), $bar, 'Should find bar with "yo@alpha^"';
is $changes->find('yo@alpha~'), $baz, 'Should find baz with "yo@alpha^"';
is $changes->find('yo@HEAD^'), $baz, 'Should find baz with yo@HEAD^';
is $changes->find('@HEAD^'), $baz, 'Should find baz with @HEAD^';
is $changes->find('@ROOT~'), $bar, 'Should find bar with @ROOT~^';
is $changes->find('HEAD^'), $baz, 'Should find baz with HEAD^';
is $changes->find('ROOT~'), $bar, 'Should find bar with ROOT~^';

ok $changes->contains('yo'), 'Should contain yo1 with "yo"';
ok $changes->contains('yo@alpha'), 'Should contain yo1 with "yo@alpha"';
ok $changes->contains('yo@HEAD'), 'Should contain yo2 with yo@HEAD';
ok $changes->contains('foo'), 'Should contain foo for "foo"';
ok $changes->contains('foo@alpha'), 'Should contain foo for "foo@alpha"';
ok $changes->contains('foo@HEAD'), 'Should contain foo for "foo@HEAD"';
ok $changes->contains('yo^'), 'Should contain bar with "yo^"';
ok $changes->contains('yo^^'), 'Should contain foo with "yo^^"';
ok $changes->contains('yo^2'), 'Should contain foo with "yo^2"';
ok $changes->contains('yo~'), 'Should contain baz with "yo~"';
ok $changes->contains('yo~~'), 'Should contain yo2 with "yo~~"';
ok $changes->contains('yo~2'), 'Should contain yo2 with "yo~2"';
ok $changes->contains('yo@alpha^'), 'Should contain bar with "yo@alpha^"';
ok $changes->contains('yo@alpha~'), 'Should contain baz with "yo@alpha^"';
ok $changes->contains('yo@HEAD^'), 'Should contain baz with yo@HEAD^';
ok $changes->contains('@HEAD^'), 'Should contain baz with @HEAD^';
ok $changes->contains('@ROOT~'), 'Should contain bar with @ROOT~^';
ok $changes->contains('HEAD^'), 'Should contain baz with HEAD^';
ok $changes->contains('ROOT~'), 'Should contain bar with ROOT~^';

throws_ok { $changes->get('yo') } 'App::Sqitch::X',
    'Should get multiple indexes error looking for index of "yo"';
is $@->ident, 'plan', 'Multiple indexes error ident should be "plan"';
is $@->message, __x(
    'Key {key} at multiple indexes',
    key => 'yo',
), 'Multiple indexes message should be correct';

throws_ok { $changes->get('yo@howdy') } 'App::Sqitch::X',
    'Should unknown tag error for invalid tag';
is $@->ident, 'plan', 'Unknown tag error ident should be "plan"';
is $@->message, __x(
    'Unknown tag "{tag}"',
    tag => '@howdy',
), 'Unknown taf message should be correct';

my $hi = App::Sqitch::Plan::Change->new(plan => $plan, name => 'hi');
ok $changes->append($hi), 'Push hi';
is $changes->count, 6, 'Count should now be six';
is_deeply [$changes->changes], [$foo, $bar, $yo1, $baz, $yo2, $hi],
    'Changes should be in order with $hi at the end';
is $changes->index_of('hi'), 5, 'Should find "hi" at index 5';
is $changes->index_of($hi->id), 5, 'Should find "hi" by ID at index 5';
is $changes->index_of($hi->old_id), 5, 'Should find "hi" by old ID at index 5';
is $changes->index_of('@ROOT'), 0, 'Index of @ROOT should still be 0';
is $changes->index_of('@HEAD'), 5, 'Index of @HEAD should now be 5';
is $changes->index_of('ROOT'), 0, 'Index of ROOT should still be 0';
is $changes->index_of('HEAD'), 5, 'Index of HEAD should now be 5';

# Now try first_index_of().
is $changes->first_index_of('non'), undef, 'First index of "non" should be undef';
is $changes->first_index_of('foo'), 0, 'First index of "foo" should be 0';
is $changes->first_index_of('foo~'), 1, 'First index of "foo~" should be 1';
is $changes->first_index_of('foo~~'), 2, 'First index of "foo~~" should be 2';
is $changes->first_index_of('foo~3'), 3, 'First index of "foo~3" should be 3';
is $changes->first_index_of('foo~~~'), undef, 'Should not find first index of "foo~~~"';
is $changes->first_index_of('foo', '@ROOT'), undef, 'First index of "foo" since @ROOT should be undef';
is $changes->first_index_of('bar'), 1, 'First index of "bar" should be 1';
is $changes->first_index_of('yo'), 2, 'First index of "yo" should be 2';
is $changes->first_index_of('yo', '@ROOT'), 2, 'First index of "yo" since @ROOT should be 2';
is $changes->first_index_of('baz'), 3, 'First index of "baz" should be 3';
is $changes->first_index_of('baz^'), 2, 'First index of "baz^" should be 2';
is $changes->first_index_of('baz^^'), 1, 'First index of "baz^^" should be 1';
is $changes->first_index_of('baz^3'), 0, 'First index of "baz^3" should be 0';
is $changes->first_index_of('baz^^^'), undef, 'Should not find first index of "baz^^^"';
is $changes->first_index_of('yo', '@alpha'), 4,
    'First index of "yo" since "@alpha" should be 4';
is $changes->first_index_of('yo', 'baz'), 4,
    'First index of "yo" since "baz" should be 4';
is $changes->first_index_of('yo^', 'baz'), 3,
    'First index of "yo^" since "baz" should be 4';
is $changes->first_index_of('yo~', 'baz'), 5,
    'First index of "yo~" since "baz" should be 5';
throws_ok { $changes->first_index_of('baz', 'nonexistent') } 'App::Sqitch::X',
    'Should get an exception for an unknown change passed to first_index_of()';
is $@->ident, 'plan', 'Unknown change error ident should be "plan"';
is $@->message, __x(
    'Unknown change: "{change}"',
    change => 'nonexistent',
), 'Unknown change message should be correct';

# Try appending a couple more changes.
my $so = App::Sqitch::Plan::Change->new(plan => $plan, name => 'so');
my $fu = App::Sqitch::Plan::Change->new(plan => $plan, name => 'fu');
ok $changes->append($so, $fu), 'Push so and fu';
is $changes->count, 8, 'Count should now be eight';
is $changes->index_of('@ROOT'), 0, 'Index of @ROOT should remain 0';
is $changes->index_of('@HEAD'), 7, 'Index of @HEAD should now be 7';
is $changes->index_of('ROOT'), 0, 'Index of ROOT should remain 0';
is $changes->index_of('HEAD'), 7, 'Index of HEAD should now be 7';
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
is $changes->get($beta->old_id), $yo2, 'Should find yo2 via @beta old ID';
is_deeply [$changes->tags], [$alpha, $beta], 'Tags should return both tags';

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

# Try an empty change list.
isa_ok $changes = App::Sqitch::Plan::ChangeList->new,
    'App::Sqitch::Plan::ChangeList';
for my $ref (qw(
    foo
    bar
    HEAD
    @HEAD
    ROOT
    @ROOT
    alpha
    @alpha
    FIRST
    @FIRST
    LAST
    @LAST
)) {
    is $changes->index_of($ref), undef,
        qq{Should not find index of "$ref" in empty list};
    is $changes->first_index_of($ref), undef,
        qq{Should not find first index of "$ref" in empty list};
    is $changes->get($ref), undef,
        qq{Should get undef for "$ref" in empty list};
    ok !$changes->contains($ref),
        qq{Should not contain "$ref" in empty list};
    is $changes->find($ref), undef,
        qq{Should find undef for "$ref" in empty list};
}
