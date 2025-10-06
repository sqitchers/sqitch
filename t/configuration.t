#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 23;
#use Test::More 'no_plan';
use File::Spec;
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
ok !$config->initialized, 'Should not be initialized';

my $hd = $^O eq 'MSWin32' && "$]" < '5.016' ? $ENV{HOME} || $ENV{USERPROFILE} : (glob('~'))[0];
is $CLASS->home_dir, $hd, 'Should have home directory';

SKIP: {
    skip 'System dir can be modified at build time', 1
        if $INC{'App/Sqitch/Config.pm'} =~ /\bblib\b/;
    is $config->system_dir, File::Spec->catfile(
        $Config::Config{prefix}, 'etc', 'sqitch'
    ), 'Default system directory should be correct';
}

is $config->user_dir, File::Spec->catfile(
    $hd, '.sqitch'
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
    $hd, '.sqitch', 'sqitch.conf'
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
isa_ok $config = $CLASS->new, $CLASS, 'Another config object';
ok $config->initialized, 'Should be initialized';
is_deeply $config->get_section(section => 'core'), {
    engine    => "pg",
    extension => "ddl",
    top_dir   => "migrations",
    uri       => 'https://github.com/sqitchers/sqitch/',
    pager     => "less -r",
}, 'get_section("core") should work';

is_deeply $config->get_section(section => 'engine.pg'), {
    client => "/usr/local/pgsql/bin/psql",
}, 'get_section("engine.pg") should work';

# Make sure it works with irregular casing.
is_deeply $config->get_section(section => 'foo.BAR'), {
    baz => 'hello',
    yep => undef,
}, 'get_section() whould work with capitalized subsection';

# Should work with multiple subsections and case-preserved keys.
is_deeply $config->get_section(section => 'guess.Yes.No'), {
    red => 'true',
    Calico => 'false',
}, 'get_section() whould work with mixed case subsections';
