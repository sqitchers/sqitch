#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 5;
#use Test::More 'no_plan';
use File::Spec;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

is_deeply $CLASS->_load_config, {},
    'Should have no config by default';

my $config_ini = {
    'core.pg' => {
        client   => '/opt/local/pgsql/bin/psql',
        username => 'postgres',
        host     => 'localhost',
    },
    'core.mysql' => {
        client   => '/opt/local/mysql/bin/mysql',
        username => 'root',
    },
    'core.sqlite' => {
        client => '/opt/local/bin/sqlite3',
    }
};

# Test loding the global config.
GLOBAL: {
    local $ENV{SQITCH_GLOBAL_CONFIG_ROOT} = 't';
    is_deeply $CLASS->_load_config, $config_ini,
        'Should load config.ini for global config';
}

my $sqitch_ini = {
    "core" => {
        db        => "widgetopolis",
        engine    => "pg",
        extension => "ddl",
        sql_dir   => "migrations",
    },
    "core.pg" => {
        client   => "/usr/local/pgsql/bin/psql",
        username => "theory",
    },
    "revert" => {
        to => "gamma",
    },
    "bundle" => {
        dest_dir  => "_build/sql",
        from      => "gamma",
        tags_only => "yes",
    },
};

chdir 't';
# Test loading local file.
is_deeply $CLASS->_load_config, $sqitch_ini,
    'Should load sqitch.ini for local config';

my $both_ini = {
    "core" => {
        db        => "widgetopolis",
        engine    => "pg",
        extension => "ddl",
        sql_dir   => "migrations",
    },
    "core.pg" => {
        client   => "/usr/local/pgsql/bin/psql",
        username => "theory",
        host     => 'localhost',
    },
    'core.mysql' => {
        client   => '/opt/local/mysql/bin/mysql',
        username => 'root',
    },
    'core.sqlite' => {
        client => '/opt/local/bin/sqlite3',
    },
    "revert" => {
        to => "gamma",
    },
    "bundle" => {
        dest_dir  => "_build/sql",
        from      => "gamma",
        tags_only => "yes",
    },
};

# Test merging.
$ENV{SQITCH_GLOBAL_CONFIG_ROOT} = File::Spec->curdir;
is_deeply $CLASS->_load_config, $both_ini,
    'Should merge both ini files with both present';
