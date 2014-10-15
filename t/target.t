#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 142;
use Test::More 'no_plan';
use App::Sqitch;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::Target';
    use_ok $CLASS or die;
}

##############################################################################
# Load a target and test the basics.
ok my $sqitch = App::Sqitch->new(options => { engine => 'sqlite'}),
    'Load a sqitch sqitch object';
isa_ok my $x = $CLASS->new(sqitch => $sqitch), $CLASS;
