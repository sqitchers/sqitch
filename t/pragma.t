#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 10;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Pragma';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    hspace
    ropspace
    lopspace
    note
    plan
    value
);

my $sqitch = App::Sqitch->new(options => { engine => 'sqlite' });
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target);
isa_ok my $dir = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
), $CLASS;
isa_ok $dir, 'App::Sqitch::Plan::Line';

is $dir->format_name, '%foo', 'Name should format as "%foo"';
is $dir->format_value, '', 'Value should format as ""';
is $dir->as_string, '%foo', 'should stringify to "%foo"';

ok $dir = $CLASS->new(
    name     => 'howdy',
    value    => 'woody',
    plan     => $plan,
    lspace   => '  ',
    hspace   => ' ',
    rspace   => "\t",
    lopspace => '   ',
    operator => '=',
    ropspace => ' ',
    note     => 'blah blah blah',
), 'Create pragma with more stuff';

is $dir->as_string, "  % howdy   = woody\t# blah blah blah",
    'It should stringify correctly';
