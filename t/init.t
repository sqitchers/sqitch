#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 87;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::Exception;
use Test::File::Contents;
use File::Path qw(remove_tree make_path);
use lib 't/lib';
use MockCommand;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command::init';
    use_ok $CLASS or die;
}

isa_ok $CLASS, 'App::Sqitch::Command', $CLASS;
chdir 't';

sub read_config($) {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

##############################################################################
# Test make_directories.
my $sqitch = App::Sqitch->new(sql_dir => dir 'init.mkdir');
isa_ok my $init = $CLASS->new(sqitch => $sqitch), $CLASS, 'New init object';

can_ok $init, 'make_directories';
for my $attr (map { "$_\_dir"} qw(sql deploy revert test)) {
    dir_not_exists_ok $sqitch->$attr;
}

my $sql_dir = $sqitch->sql_dir->stringify;
END { remove_tree $sql_dir }

ok $init->make_directories, 'Make the directories';
for my $attr (map { "$_\_dir"} qw(sql deploy revert test)) {
    dir_exists_ok $sqitch->$attr;
}
is_deeply +MockCommand->get_info, [
    map { ["Created " . $sqitch->$_] } map { "$_\_dir" } qw(deploy revert test)
], 'Each should have been sent to info';

# Do it again.
ok $init->make_directories, 'Make the directories again';
is_deeply +MockCommand->get_info, [], 'Nothing should have been sent to info';

# Delete one of them.
remove_tree $sqitch->revert_dir->stringify;
ok $init->make_directories, 'Make the directories once more';
dir_exists_ok $sqitch->revert_dir, 'revert dir exists again';
is_deeply +MockCommand->get_info, [
    ['Created ' . $sqitch->revert_dir],
], 'Should have noted creation of revert dir';

# Handle errors.
remove_tree $sql_dir;
make_path $sql_dir;
chmod 0000, $sql_dir;
END { chmod 0400, $sql_dir }
throws_ok { $init->make_directories } qr/FAIL/, 'Should fail on permissio issue';
is_deeply +MockCommand->get_fail, [
    ['Error creating ' . $sqitch->deploy_dir . ': Permission denied'],
], 'Failure should have been emitted';

##############################################################################
# Test write_config().
can_ok $init, 'write_config';

my $test_dir = 'init.write';
make_path $test_dir;
END { remove_tree $test_dir }
chdir $test_dir;
END { chdir File::Spec->updir }
my $conf_file = $sqitch->config->local_file;

$sqitch = App::Sqitch->new(extension => 'foo');
ok $init = $CLASS->new(sqitch => $sqitch), 'Anogher init object';

file_not_exists_ok $conf_file;

# Write config.
ok $init->write_config, 'Write the config';
file_exists_ok $conf_file;
is_deeply read_config $conf_file, {
    'core.extension' => 'foo',
}, 'The configuration should have been written with only one setting';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info';

file_contents_like $conf_file, qr{\Q
	# engine = 
	# plan_file = sqitch.plan
	# sql_dir = sql
	# deploy_dir = sql/deploy
	# revert_dir = sql/revert
	# test_dir = sql/test
}m, 'Other settings should be commented-out';

# Go again.
ok $init->write_config, 'Write the config again';
is_deeply read_config $conf_file, {
    'core.extension' => 'foo',
}, 'The configuration should be unchanged';
is_deeply +MockCommand->get_info, [
], 'Nothing should have been sent to info';

USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new(extension => 'foo');
    ok my $init = $CLASS->new(sqitch => $sqitch), 'Make an init object with user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with a user conf';
    file_exists_ok $conf_file;
    is_deeply read_config $conf_file, {
        'core.extension' => 'foo',
    }, 'The configuration should just have core.sql_dir';
    is_deeply +MockCommand->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info again';
    file_contents_like $conf_file, qr{\Q
	# engine = 
	# plan_file = sqitch.plan
	# sql_dir = sql
	# deploy_dir = sql/deploy
	# revert_dir = sql/revert
	# test_dir = sql/test
}m, 'Other settings should be commented-out';
}

SYSTEMCONF: {
    # Delete the file and write with a system config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_SYSTEM_CONFIG} = file +File::Spec->updir, 'sqitch.conf';
    my $sqitch = App::Sqitch->new(extension => 'foo');
    ok my $init = $CLASS->new(sqitch => $sqitch), 'Make an init object with system config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with a system conf';
    file_exists_ok $conf_file;
    is_deeply read_config $conf_file, {
        'core.extension' => 'foo',
        'core.engine' => 'pg',
    }, 'The configuration should just have core.sql_dir';
    is_deeply +MockCommand->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info again';
    file_contents_like $conf_file, qr{\Q
	# plan_file = sqitch.plan
	# sql_dir = migrations
	# deploy_dir = migrations/deploy
	# revert_dir = migrations/revert
	# test_dir = migrations/test
}m, 'Other settings should be commented-out';
}

##############################################################################
# Now get it to write a bunch of other stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    plan_file  => 'my.plan',
    deploy_dir => 'dep',
    revert_dir => 'rev',
    test_dir   => 'tst',
    extension  => 'ddl',
    _engine    => 'sqlite',
);

ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch non-default attributes';
ok $init->write_config, 'Write the config with core attrs';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info once more';

is_deeply read_config $conf_file, {
    'core.plan_file'  => 'my.plan',
    'core.deploy_dir' => 'dep',
    'core.revert_dir' => 'rev',
    'core.test_dir'   => 'tst',
    'core.extension'  => 'ddl',
    'core.engine'     => 'sqlite',
}, 'The configuration should have been written with all the core values';

##############################################################################
# Now get it to write core.sqlite stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    _engine => 'sqlite',
    client  => '/to/sqlite3',
    db_name => 'my.db',
);

ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch with non-default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info yet again';

is_deeply read_config $conf_file, {
    'core.engine'         => 'sqlite',
    'core.sqlite.client'  => '/to/sqlite3',
    'core.sqlite.db_name' => 'my.db',
}, 'The configuration should have been written with sqlite values';

file_contents_like $conf_file, qr/^\t# sqitch_prefix = sqitch\n/m,
    'sqitch_prefix should be included in a comment';

# Try it with no options.
unlink $conf_file;
$sqitch = App::Sqitch->new(_engine => 'sqlite');
ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch with default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info again again';
is_deeply read_config $conf_file, {
    'core.engine'         => 'sqlite',
}, 'The configuration should have been written with only the engine var';

file_contents_like $conf_file, qr{^\Q# [core "sqlite"]
	# sqitch_prefix = sqitch
	# db_name = 
	# client = sqlite3
}m, 'Engine section should be present but commented-out';

# Now build it with other config.
USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new(
        _engine => 'sqlite',
        db_name => 'my.db',
    );
    ok my $init = $CLASS->new(sqitch => $sqitch),
        'Make an init with sqlite and user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with sqlite config';
    is_deeply +MockCommand->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info once more';

    is_deeply read_config $conf_file, {
        'core.engine'         => 'sqlite',
        'core.sqlite.db_name' => 'my.db',
    }, 'New config should have been written with sqlite values';

    file_contents_like $conf_file, qr{^\t# client = /opt/local/bin/sqlite3\E\n}m,
        'Configured client should be included in a comment';

    file_contents_like $conf_file, qr/^\t# sqitch_prefix = meta\n/m,
        'Configured sqitch_prefix should be included in a comment';
}

##############################################################################
# Now get it to write core.pg stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    _engine  => 'pg',
    client   => '/to/psql',
    db_name  => 'thingies',
    username => 'anna',
    host     => 'banana',
    port     => 93453,
);

ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch with more non-default engine attributes';
ok $init->write_config, 'Write the config with more engine attrs';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info one more time';

is_deeply read_config $conf_file, {
    'core.engine'      => 'pg',
    'core.pg.client'   => '/to/psql',
    'core.pg.db_name'  => 'thingies',
    'core.pg.username' => 'anna',
    'core.pg.host'     => 'banana',
    'core.pg.port'     => 93453,
}, 'The configuration should have been written with pg values';

file_contents_like $conf_file, qr/^\t# sqitch_schema = sqitch\n/m,
    'sqitch_schema should be included in a comment';
file_contents_like $conf_file, qr/^\t# password = \n/m,
    'password should be included in a comment';

# Try it with no config or options.
unlink $conf_file;
$sqitch = App::Sqitch->new(_engine => 'pg');
ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch with default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockCommand->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info again again again';
is_deeply read_config $conf_file, {
    'core.engine'         => 'pg',
}, 'The configuration should have been written with only the engine var';

file_contents_like $conf_file, qr{^\Q# [core "pg"]
	# db_name = 
	# client = psql
	# sqitch_schema = sqitch
	# password = 
	# port = 
	# host = 
	# username = 
}m, 'Engine section should be present but commented-out';

USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new(
        _engine  => 'pg',
        db_name  => 'thingies',
    );
    ok my $init = $CLASS->new(sqitch => $sqitch),
        'Make an init with pg and user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with pg config';
    is_deeply +MockCommand->get_info, [
        ['Created ' . $conf_file]
    ], 'The pg config creation should be sent to info';

    is_deeply read_config $conf_file, {
        'core.engine'      => 'pg',
        'core.pg.db_name'  => 'thingies',
    }, 'The configuration should have been written with pg options';

    file_contents_like $conf_file, qr/^\t# sqitch_schema = meta\n/m,
        'Configured sqitch_schema should be in a comment';
    file_contents_like $conf_file, qr/^\t# password = \n/m,
        'password should be included in a comment';
    file_contents_like $conf_file, qr/^\t# username = postgres\n/m,
        'Configured username should be in a comment';
    file_contents_like $conf_file, qr/^\t# host = localhost\n/m,
        'Configured host should be in a comment';
}
