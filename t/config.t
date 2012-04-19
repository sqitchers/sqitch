#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 15;
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
        db_name   => "widgetopolis",
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
        db_name   => "widgetopolis",
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

##############################################################################
# Test the command.
ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'config',
}), 'App::Sqitch::Command::config', 'Config command';

isa_ok $cmd, 'App::Sqitch::Command', 'Config command';
can_ok $cmd, qw(
    get
    user
    system
    config_file
    unset
    list
    edit
);
is_deeply [$cmd->options], [qw(
    get
    user
    system
    config-file|file|f=s
    unset
    list|l
    edit|e
)], 'Options should be configured';

##############################################################################
# Test config file name.
is $cmd->config_file, File::Spec->catfile(File::Spec->curdir, 'sqitch.ini'),
    'Default config file should be local config file';

# Test user file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    user    => 1,
}), 'App::Sqitch::Command::config', 'User config command';

is $cmd->config_file, File::Spec->catfile($sqitch->_user_config_root, 'config.ini'),
    'User config file should be in user config root';

# Test system file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    system  => 1,
}), 'App::Sqitch::Command::config', 'System config command';

is $cmd->config_file, File::Spec->catfile($Config::Config{prefix}, qw(etc sqitch.ini)),
    "System config file should be in $Config::Config{prefix}/etc";

##############################################################################
