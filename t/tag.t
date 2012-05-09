#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 8;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use App::Sqitch::Plan::Step;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Tag';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    names
    plan
    steps
);

my $sqitch = App::Sqitch->new;
isa_ok my $tag = $CLASS->new(
    names  => ['foo'],
    plan   => App::Sqitch::Plan->new(sqitch => $sqitch),
), $CLASS;

is_deeply [$tag->names], ['foo'], 'Names should be a list';
is_deeply [$tag->steps], [], 'Should have no steps';

my $step = App::Sqitch::Plan::Step->new(
    name => 'one',
    tag  => $tag,
);

ok push(@{ $tag->_steps } => $step), 'Add a step';
is_deeply [$tag->steps], [$step], 'Should have the one step';
