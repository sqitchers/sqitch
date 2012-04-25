#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
use Test::More tests => 1;
#use Test::More 'no_plan';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command::init';
    use_ok $CLASS or die;
}
