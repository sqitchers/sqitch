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

# protect against user's environment variables
delete @ENV{qw( SQITCH_CONFIG SQITCH_USER_CONFIG SQITCH_SYSTEM_CONFIG )};

isa_ok my $config = $CLASS->new, $CLASS, 'New config object';
is $config->confname, 'sqitch.conf', 'confname should be "sqitch.conf"';

SKIP: {
    skip 'System dir can be modified at build time', 1
        if $INC{'App/Sqitch/Config.pm'} =~ /\bblib\b/;
    is $config->system_dir, File::Spec->catfile(
        $Config::Config{prefix}, 'etc', 'sqitch'
    ), 'Default system directory should be correct';
}

is $config->user_dir, File::Spec->catfile(
    File::HomeDir->my_home, '.sqitch'
), 'Default user directory should be correct';

is $config->global_file, File::Spec->catfile(
    $config->system_dir, 'sqitch.conf'
), 'Default global file name should be correct';

my $file = File::Spec->catfile(qw(FOO BAR));
$ENV{SQITCH_SYSTEM_CONFIG} = $file;
is $config->global_file, $file,
    'Should preferably get SQITCH_SYSTEM_CONFIG file from global_file';
is $config->system_file, $config->global_file, 'system_file should alias global_file';

is $config->user_file, File::Spec->catfile(
    File::HomeDir->my_home, '.sqitch', 'sqitch.conf'
), 'Default user file name should be correct';

$ENV{SQITCH_USER_CONFIG} = $file,
is $config->user_file, $file,
    'Should preferably get SQITCH_USER_CONFIG file from user_file';

is $config->local_file, 'sqitch.conf',
    'Local file should be correct';
is $config->dir_file, $config->local_file, 'dir_file should alias local_file';

SQITCH_CONFIG: {
    local $ENV{SQITCH_CONFIG} = 'sqitch.ini';
    is $config->local_file, 'sqitch.ini', 'local_file should prefer $SQITCH_CONFIG';
    is $config->dir_file, 'sqitch.ini', 'And so should dir_file';
}

chdir 't';
is_deeply $config->get_section(section => 'core'), {
    engine    => "pg",
    extension => "ddl",
    top_dir   => "migrations",
    uri       => 'https://github.com/theory/sqitch/',
    pager     => "less -r",
}, 'get_section("core") should work';

is_deeply $config->get_section(section => 'engine.pg'), {
    client => "/usr/local/pgsql/bin/psql",
}, 'get_section("engine.pg") should work';

