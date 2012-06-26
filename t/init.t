#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 110;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::Exception;
use Test::File::Contents;
use File::Path qw(remove_tree make_path);
use lib 't/lib';
use MockOutput;

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
my $sqitch = App::Sqitch->new(top_dir => dir 'init.mkdir');
isa_ok my $init = $CLASS->new(sqitch => $sqitch), $CLASS, 'New init object';

can_ok $init, 'make_directories';
for my $attr (map { "$_\_dir"} qw(top deploy revert test)) {
    dir_not_exists_ok $sqitch->$attr;
}

my $top_dir = $sqitch->top_dir->stringify;
END { remove_tree $top_dir }

ok $init->make_directories, 'Make the directories';
for my $attr (map { "$_\_dir"} qw(top deploy revert test)) {
    dir_exists_ok $sqitch->$attr;
}
is_deeply +MockOutput->get_info, [
    map { ["Created " . $sqitch->$_] } map { "$_\_dir" } qw(deploy revert test)
], 'Each should have been sent to info';

# Do it again.
ok $init->make_directories, 'Make the directories again';
is_deeply +MockOutput->get_info, [], 'Nothing should have been sent to info';

# Delete one of them.
remove_tree $sqitch->revert_dir->stringify;
ok $init->make_directories, 'Make the directories once more';
dir_exists_ok $sqitch->revert_dir, 'revert dir exists again';
is_deeply +MockOutput->get_info, [
    ['Created ' . $sqitch->revert_dir],
], 'Should have noted creation of revert dir';

# Handle errors.
remove_tree $top_dir;
make_path $top_dir;
chmod 0000, $top_dir;
END { chmod 0400, $top_dir }
throws_ok { $init->make_directories } qr/FAIL/, 'Should fail on permissio issue';
is_deeply +MockOutput->get_fail, [
    ['Error creating ' . $sqitch->deploy_dir . ': Permission denied'],
], 'Failure should have been emitted';

##############################################################################
# Test write_config().
can_ok $init, 'write_config';

my $write_dir = 'init.write';
make_path $write_dir;
END { remove_tree $write_dir }
chdir $write_dir;
END { chdir File::Spec->updir }
my $conf_file = $sqitch->config->local_file;

# Mock UUID::Tiny.
my $uuid_mock = Test::MockModule->new('UUID::Tiny');
my $uuid_type;
$uuid_mock->mock(create_uuid_as_string => sub {
    $uuid_type = shift;
    return 'bb70577f-56d6-488c-bbcb-6d093f81de91';
});
my $uri = 'urn:uuid:bb70577f-56d6-488c-bbcb-6d093f81de91';

$sqitch = App::Sqitch->new;
ok $init = $CLASS->new(sqitch => $sqitch), 'Another init object';
file_not_exists_ok $conf_file;

# Write empty config.
ok $init->write_config, 'Write the config';
file_exists_ok $conf_file;
is_deeply read_config $conf_file, {
    'core.uri' => $uri,
}, 'The configuration file should have one variable';
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info';
is $uuid_type, UUID::Tiny::UUID_V4(), 'Should use a V4 UUID';
my $deploy_dir = File::Spec->catfile(qw(sql deploy));
my $revert_dir = File::Spec->catfile(qw(sql revert));
my $test_dir   = File::Spec->catfile(qw(sql test));
file_contents_like $conf_file, qr{\Q[core]
	uri = $uri
	# engine = 
	# plan_file = sqitch.plan
	# top_dir = sql
	# deploy_dir = $deploy_dir
	# revert_dir = $revert_dir
	# test_dir = $test_dir
	# extension = sql
}m, 'All but URI in core section should be commented-out';
unlink $conf_file;

# Set two options.
$sqitch = App::Sqitch->new(
    extension => 'foo',
    uri       => URI->new('https://github.com/theory/sqitch/'),
);
ok $init = $CLASS->new(sqitch => $sqitch), 'Another init object';
ok $init->write_config, 'Write the config';
file_exists_ok $conf_file;
is_deeply read_config $conf_file, {
    'core.uri'       => 'https://github.com/theory/sqitch/',
    'core.extension' => 'foo',
}, 'The configuration should have been written with the two settings';
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info';

file_contents_like $conf_file, qr{
	# engine = 
	# plan_file = sqitch.plan
	# top_dir = sql
	# deploy_dir = $deploy_dir
	# revert_dir = $revert_dir
	# test_dir = $test_dir
}m, 'Other settings should be commented-out';

# Go again.
ok $init->write_config, 'Write the config again';
is_deeply read_config $conf_file, {
    'core.uri'       => 'https://github.com/theory/sqitch/',
    'core.extension' => 'foo',
}, 'The configuration should be unchanged';
is_deeply +MockOutput->get_info, [
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
        'core.uri' => $uri,
        'core.extension' => 'foo',
    }, 'The configuration should just have core.uri and core.top_dir';
    is_deeply +MockOutput->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info again';
    file_contents_like $conf_file, qr{\Q
	# engine = 
	# plan_file = sqitch.plan
	# top_dir = sql
	# deploy_dir = $deploy_dir
	# revert_dir = $revert_dir
	# test_dir = $test_dir
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
        'core.uri' => $uri,
        'core.extension' => 'foo',
        'core.engine' => 'pg',
        'core.uri' => URI->new('https://github.com/theory/sqitch/'),
    }, 'The configuration should have local and system config';
    is_deeply +MockOutput->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info again';

    my $deploy_dir = File::Spec->catfile(qw(migrations deploy));
    my $revert_dir = File::Spec->catfile(qw(migrations revert));
    my $test_dir   = File::Spec->catfile(qw(migrations test));
    file_contents_like $conf_file, qr{\Q
	# plan_file = sqitch.plan
	# top_dir = migrations
	# deploy_dir = $deploy_dir
	# revert_dir = $revert_dir
	# test_dir = $test_dir
}m, 'Other settings should be commented-out';
}

##############################################################################
# Now get it to write a bunch of other stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    plan_file  => 'my.plan',
    deploy_dir => dir('dep'),
    revert_dir => dir('rev'),
    test_dir   => dir('tst'),
    extension  => 'ddl',
    _engine    => 'sqlite',
);

ok $init = $CLASS->new(sqitch => $sqitch),
    'Create new init with sqitch non-default attributes';
ok $init->write_config, 'Write the config with core attrs';
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info once more';

is_deeply read_config $conf_file, {
    'core.uri'        => $uri,
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
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info yet again';

is_deeply read_config $conf_file, {
    'core.uri'            => $uri,
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
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info again again';
is_deeply read_config $conf_file, {
    'core.uri'    => $uri,
    'core.engine' => 'sqlite',
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
    is_deeply +MockOutput->get_info, [
        ['Created ' . $conf_file]
    ], 'The creation should be sent to info once more';

    is_deeply read_config $conf_file, {
        'core.uri'            => $uri,
        'core.engine'         => 'sqlite',
        'core.sqlite.db_name' => 'my.db',
    }, 'New config should have been written with sqlite values';

    file_contents_like $conf_file, qr{^\t\Q# client = /opt/local/bin/sqlite3\E\n}m,
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
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info one more time';

is_deeply read_config $conf_file, {
    'core.uri'         => $uri,
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
is_deeply +MockOutput->get_info, [
    ['Created ' . $conf_file]
], 'The creation should be sent to info again again again';
is_deeply read_config $conf_file, {
    'core.uri'    => $uri,
    'core.engine' => 'pg',
}, 'The configuration should have been written with only the uri & engine vars';

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
    is_deeply +MockOutput->get_info, [
        ['Created ' . $conf_file]
    ], 'The pg config creation should be sent to info';

    is_deeply read_config $conf_file, {
        'core.uri'         => $uri,
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

##############################################################################
# Test write_plan().
can_ok $init, 'write_plan';
my $plan_file = $sqitch->plan_file;
file_not_exists_ok $plan_file, 'Plan file should not yet exist';
ok $init->write_plan, 'Write the plan file';
is_deeply +MockOutput->get_info, [
    ['Created ' . $plan_file]
], 'The plan creation should be sent to info';
file_exists_ok $plan_file, 'Plan file should now exist';
file_contents_is $plan_file,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION() . "\n\n",
 'The contents should be correct';

# Write more to the plan.
my $fh = $plan_file->open('>:utf8') or die "Cannot open $plan_file: $!\n";
$fh->say('# testing 1, 2, 3');
$fh->close;

# Try writing again.
ok $init->write_plan, 'Write the plan file again';
file_contents_like $plan_file, qr/testing 1, 2, 3/,
    'The file should not be overwritten';

##############################################################################
# Bring it all together, yo.
remove_tree $top_dir;
unlink $conf_file;
unlink $plan_file;
ok $init->execute, 'Execute!';

# Should have directories.
for my $attr (map { "$_\_dir"} qw(top deploy revert test)) {
    dir_exists_ok $sqitch->$attr;
}

# Should have config and plan.
file_exists_ok $conf_file;
file_exists_ok $plan_file;

# Shoudld have the output.
my @dir_messages = map {
    ["Created " . $sqitch->$_] } map { "$_\_dir"
} qw(deploy revert test);
is_deeply +MockOutput->get_info, [
    @dir_messages,
    ['Created ' . $conf_file],
    ['Created ' . $plan_file],
], 'Should have status messages';
