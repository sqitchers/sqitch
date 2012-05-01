#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 54;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    all
    position
    _parse
);

my $sqitch = App::Sqitch->new;
isa_ok my $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS;

sub tag {
    App::Sqitch::Plan::Tag->new(names => $_[0], steps => $_[1])
}

##############################################################################
# Test parsing.
my $file = file qw(t plans widgets.plan);
is_deeply $plan->_parse($file), [
    tag [qw(foo)] => [qw(hey you)],
], 'Should parse simple "widgets.plan"';

# Plan with multiple tags.
$file = file qw(t plans multi.plan);
is_deeply $plan->_parse($file), [
    tag( [qw(foo)] => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
], 'Should parse multi-tagged "multi.plan"';

# Try a plan with steps appearing without a tag.
$file = file qw(t plans steps-only.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
    'Should die on plan with steps beore tags';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': step "hey" not associated with a tag',
]], 'And the error should have been output';

# Try a plan with a bad step name.
$file = file qw(t plans bad-step.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
    'Should die on plan with bad step name';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': "what what what"',
]], 'And the error should have been output';

# Make sure the plan parses the plan.
$file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan file';
is_deeply [$plan->all], [
    tag( [qw(foo)] => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
], 'plan should be parsed from file';

##############################################################################
# Test the interator interface.
can_ok $plan, qw(
    seek
    reset
    next
    current
    peek
    do
);

is $plan->position, -1, 'Position should start at -1';
is $plan->current, undef, 'Current should be undef';
ok my $tag = $plan->next, 'Get next tag';
is $tag->names->[0], 'foo', 'Tag should be the first tag';
is $plan->position, 0, 'Position should be at 0';
is $plan->current, $tag, 'Current should be current';
ok my $next = $plan->peek, 'Peek to next tag';
is $next->names->[0], 'bar', 'Peeked tag should be second tag';
is $plan->current, $tag, 'Current should still be current';
is $plan->peek, $next, 'Peek should still be next';
is $plan->next, $next, 'Next should be the second tag';
is $plan->position, 1, 'Position should be at 1';
is $plan->peek, undef, 'Peek should return undef';
is $plan->current, $next, 'Current should be the second tag';
is $plan->next, undef, 'Next should return undef';
is $plan->position, 2, 'Position should be at 2';
is $plan->current, undef, 'Current should be undef';
is $plan->next, undef, 'Next should still be undef';
is $plan->position, 2, 'Position should still be at 2';
ok $plan->reset, 'Reset the plan';
is $plan->position, -1, 'Position should be back at -1';
is $plan->current, undef, 'Current should still be undef';
is $plan->next, $tag, 'Next should return the first tag again';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $tag, 'Current should be first tag';
ok $plan->seek('bar'), 'Seek to the "bar" tag';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';
ok $plan->seek('foo'), 'Seek to the "foo" tag';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $tag, 'Current should be first again';
ok $plan->seek('baz'), 'Seek to the "baz" tag';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';

# Make sure seek() chokes on a bad tag name.
throws_ok { $plan->seek('nonesuch') } qr/FAIL:/,
    'Should die seeking invalid tag';
is_deeply +MockOutput->get_fail, [['Cannot find tag "nonesuch" in plan']],
    'And the failure should be sent to output';

# Get all!
is_deeply [$plan->all], [$tag, $next], 'All should return all tags';
my @e = ($tag, $next);
ok $plan->reset, 'Reset the plan again';
$plan->do(sub {
    is shift, $e[0], 'Tag ' . $e[0]->names->[0] . ' should be passed to do sub';
    is $_, $e[0], 'Tag ' . $e[0]->names->[0] . ' should be the topic in do sub';
    shift @e;
});

# There should be no more to iterate over.
$plan->do(sub { fail 'Should not get anything passed to do()' });
