#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More tests => 2;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::sqlite';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    client        => 'any',
    db_file       => 'any',
    sqitch_prefix => 'any',
], 'config_vars should return three vars';
