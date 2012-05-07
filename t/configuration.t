#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 17;

#use Test::More 'no_plan';
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Test::NoWarnings;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Config';
    use_ok $CLASS or die;
}

isa_ok my $config = $CLASS->new, $CLASS, 'New config object';
is $config->confname, 'sqitch.conf', 'confname should be "sqitch.conf"';

SKIP: {
    skip 'System dir can be modified at build time', 1
        if $INC{'App/Sqitch/Config.pm'} =~ /\bblib\b/;
    is $config->system_dir,
        File::Spec->catfile( $Config::Config{prefix}, 'etc', 'sqitch' ),
        'Default system directory should be correct';
}

is $config->user_dir,
    File::Spec->catfile( File::HomeDir->my_home, '.sqitch' ),
    'Default user directory should be correct';

is $config->global_file,
    File::Spec->catfile( $config->system_dir, 'sqitch.conf' ),
    'Default global file name should be correct';

$ENV{SQITCH_SYSTEM_CONFIG} = 'FOO/BAR';
is $config->global_file, 'FOO/BAR',
    'Should preferably get SQITCH_SYSTEM_CONFIG file from global_file';
is $config->system_file, $config->global_file,
    'system_file should alias global_file';

is $config->user_file,
    File::Spec->catfile( File::HomeDir->my_home, '.sqitch', 'sqitch.conf' ),
    'Default user file name should be correct';

$ENV{SQITCH_USER_CONFIG} = 'FOO/BAR';
is $config->user_file, 'FOO/BAR',
    'Should preferably get SQITCH_USER_CONFIG file from user_file';

is $config->local_file, 'sqitch.conf', 'Local file should be correct';
is $config->dir_file, $config->local_file, 'dir_file should alias local_file';

SQITCH_CONFIG: {
    local $ENV{SQITCH_CONFIG} = 'sqitch.ini';
    is $config->local_file, 'sqitch.ini',
        'local_file should prefer $SQITCH_CONFIG';
    is $config->dir_file, 'sqitch.ini', 'And so should dir_file';
}

chdir 't';
is_deeply $config->get_section( section => 'core' ),
    {
    engine    => "pg",
    extension => "ddl",
    sql_dir   => "migrations",
    },
    'get_section("core") should work';

is_deeply $config->get_section( section => 'core.pg' ),
    {
    client   => "/usr/local/pgsql/bin/psql",
    username => "theory",
    },
    'get_section("core.pg") should work';
