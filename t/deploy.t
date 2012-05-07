#!/usr/bin/perl

use strict;
use warnings;
use v5.10;
use Test::More tests => 3;

#use Test::More 'no_plan';

my $CLASS = 'App::Sqitch::Command::deploy';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    execute
);
