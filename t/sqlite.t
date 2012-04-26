#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More tests => 8;
#use Test::More 'no_plan';
use App::Sqitch;

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

my $sqitch = App::Sqitch->new;
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'Win32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->db_file, $sqitch->db_name,
    'db_file should default to Sqitch db_name';
is $sqlite->sqitch_prefix, 'sqitch',
    'sqitch_prefix should default to "sqitch"';

# Make sure the client falls back on the sqitch attribute.
$sqitch = App::Sqitch->new(client => 'foo/bar');
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create sqlite with sqitch with client';
is $sqlite->client, 'foo/bar', 'The client should be grabbed from sqitch';
