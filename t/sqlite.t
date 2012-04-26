#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More tests => 1;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::sqlite';
    require_ok $CLASS or die;
}
