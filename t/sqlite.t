#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More tests => 13;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::MockModule;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::sqlite';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    client        => 'any',
    db_name       => 'any',
    sqitch_prefix => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch, db_name => 'foo'), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'Win32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->db_name, 'foo', 'db_name should be required';
is $sqlite->sqitch_prefix, 'sqitch',
    'sqitch_prefix should default to "sqitch"';

# Make sure it falls back on config before defaults, after options.
my %config = (
    'core.sqlite.client' => '/path/to/sqlite3',
    'core.sqlite.db_name' => '/path/to/sqlite.db',
    'core.sqlite.sqitch_prefix' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->client, '/path/to/sqlite3',
    'client should fall back on config';
is $sqlite->db_name, '/path/to/sqlite.db',
    'db_name should fall back on config';
is $sqlite->sqitch_prefix, 'meta',
    'sqitch_prefix should fall back on config';

# Make sure the client falls back on the sqitch attributes.
$sqitch = App::Sqitch->new(db_client => 'foo/bar', db_name => 'my.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create sqlite with sqitch with --client and --db-name';
is $sqlite->client, 'foo/bar', 'The client should be grabbed from sqitch';
is $sqlite->db_name, 'my.db', 'The db_name should be grabbed from sqitch';
