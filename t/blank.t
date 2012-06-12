#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 9;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Blank';
    require_ok $CLASS or die;
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

is $tag->format_name, '', 'Name should format as ""';
is $tag->as_string, '', 'should stringify to ""';

ok $tag = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    lspace  => '  ',
    rspace  => "\t",
    comment => ' blah blah blah',
), 'Create tag with more stuff';

is $tag->as_string, "  \t# blah blah blah",
    'It should stringify correctly';

