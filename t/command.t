#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
#use Test::More tests => 20;
use Test::More 'no_plan';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(load new);

