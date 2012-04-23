#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 113;
#use Test::More 'no_plan';
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Test::NoWarnings;
use Path::Class;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

ok my $sqitch = App::Sqitch->new, 'Load a sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'config',
}), 'App::Sqitch::Command::config', 'Config command';

isa_ok $cmd, 'App::Sqitch::Command', 'Config command';
can_ok $cmd, qw(file action context get set unset list edit);
is_deeply [$cmd->options], [qw(
    file|config-file|f=s
    user
    system
    get
    get-all
    add
    unset
    unset-all
    list|l
    edit|e
)], 'Options should be configured';

##############################################################################
# Test constructor errors.
my $mock = Test::MockModule->new('App::Sqitch::Command::config');
my @usage;
$mock->mock(usage => sub { shift; @usage = @_; die 'USAGE' });

# Test for multiple config file specifications.
throws_ok { App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    user    => 1,
    system  => 1,
}) } qr/USAGE/, 'Construct with user and system';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get error for multiple config files';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    file   => 't/sqitch.ini',
    system => 1,
})} qr/USAGE/, 'Construct with file and system';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get another error for multiple config files';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    file   => 't/sqitch.ini',
    user   => 1,
})} qr/USAGE/, 'Construct with file and user';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get a third error for multiple config files';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    file   => 't/sqitch.ini',
    user   => 1,
    system => 1,
})} qr/USAGE/, 'Construct with file, system, and user';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get one last error for multiple config files';

# Test for multiple action specifications.
for my $spec (
    [qw(get unset)],
    [qw(get unset edit)],
    [qw(get unset edit list)],
    [qw(unset edit)],
    [qw(unset edit list)],
    [qw(edit list)],
    [qw(edit add list)],
    [qw(edit add list get_all)],
    [qw(edit add list unset_all)],
    [qw(edit add list get_all unset_all)],
) {
    throws_ok { App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        map { $_ => 1 } @{ $spec }
    })} qr/USAGE/, 'Construct with ' . join ' & ' => @{ $spec };
    is_deeply \@usage, ['Only one action at a time.'],
        'Should get error for multiple actions';
}

##############################################################################
# Test config file name.
is $cmd->file, $sqitch->config->dir_file,
    'Default config file should be local config file';
is $cmd->action, 'set', 'Default action should be "set"';
is $cmd->context, 'project', 'Default context should be "project"';

# Test user file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    user    => 1,
}), 'App::Sqitch::Command::config', 'User config command';

is $cmd->file, $sqitch->config->user_file, 'User config file should be user';

# Test system file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    system  => 1,
}), 'App::Sqitch::Command::config', 'System config command';

is $cmd->file, $sqitch->config->system_file, 'System config file should be system';

##############################################################################
# Test execute().
my @fail;
$mock->mock(fail => sub { shift; @fail = @_; die "FAIL @_" });
my @set;
$mock->mock(set => sub { shift; @set = @_; return 1 });
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    system  => 1,
}), 'Create config set command';

ok $cmd->execute(qw(foo bar)), 'Execute the set command';
is_deeply \@set, [qw(foo bar)], 'The set method should have been called';
$mock->unmock('set');

##############################################################################
# Test get().
chdir 't';
$ENV{SQITCH_USER_CONFIG} = 'user.conf';
my @emit;
$mock->mock(emit => sub { shift; push @emit => [@_] });
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get     => 1,
}), 'Create config get command';
ok $cmd->execute('core.engine'), 'Get core.engine';
is_deeply \@emit, [['pg']], 'Should have emitted the merged core.engine';
@emit = ();

ok $cmd->execute('core.pg.host'), 'Get core.pg.host';
is_deeply \@emit, [['localhost']], 'Should have emitted the merged core.pg.host';
@emit = ();

ok $cmd->execute('core.pg.client'), 'Get core.pg.client';
is_deeply \@emit, [['/usr/local/pgsql/bin/psql']],
    'Should have emitted the merged core.pg.client';
@emit = ();
chdir File::Spec->updir;

CONTEXT: {
    local $ENV{SQITCH_SYSTEM_CONFIG} = file qw(t sqitch.conf);
    $sqitch->config->load;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        get    => 1,
    }), 'Create system config get command';
    ok $cmd->execute('core.engine'), 'Get system core.engine';
    is_deeply \@emit, [['pg']], 'Should have emitted the system core.engine';
    @emit = ();

    ok $cmd->execute('core.pg.client'), 'Get system core.pg.client';
    is_deeply \@emit, [['/usr/local/pgsql/bin/psql']],
        'Should have emitted the system core.pg.client';
    @emit = @fail = ();

    throws_ok { $cmd->execute('core.pg.host') } qr/FAIL/,
        'Attempt to get core.pg.host should fail';
    is_deeply \@emit, [], 'Nothing should have been emitted';
    is_deeply \@fail, [], 'Nothing should have been output on failure';

    local $ENV{SQITCH_USER_CONFIG} = file qw(t user.conf);
    $sqitch->config->load;
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user   => 1,
        get    => 1,
    }), 'Create user config get command';
    @emit = ();

    ok $cmd->execute('core.pg.host'), 'Get user core.pg.host';
    is_deeply \@emit, [['localhost']], 'Should have emitted the user core.pg.host';
    @emit = ();

    ok $cmd->execute('core.pg.client'), 'Get user core.pg.client';
    is_deeply \@emit, [['/opt/local/pgsql/bin/psql']],
        'Should have emitted the user core.pg.client';
    @emit = ();
}

CONTEXT: {
    # What happens when there is no config file?
    local $ENV{SQITCH_SYSTEM_CONFIG} = 'NONEXISTENT';
    $sqitch->config->load;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        get    => 1,
    }), 'Create another system config get command';
    ok !-f $cmd->file, 'There should be no system config file';
    throws_ok { $cmd->execute('core.engine') } qr/FAIL/,
        'Should fail when no system config file';
    is_deeply \@fail, [], 'Nothing should have been emitted';

    local $ENV{SQITCH_USER_CONFIG} = 'NONEXISTENT';
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user => 1,
        get    => 1,
    }), 'Create another user config get command';
    ok !-f $cmd->file, 'There should be no user config file';
    throws_ok { $cmd->execute('core.engine') } qr/FAIL/,
        'Should fail when no user config file';
    is_deeply \@fail, [], 'Nothing should have been emitted';
}

##############################################################################
# Test list().
local $ENV{SQITCH_SYSTEM_CONFIG} = file qw(t sqitch.conf);
local $ENV{SQITCH_USER_CONFIG} = file qw(t user.conf);
$sqitch->config->load;
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    list    => 1,
}), 'Create config list command';
ok $cmd->execute, 'Execute the list action';
is_deeply \@emit, [[
    "bundle.dest_dir=_build/sql
bundle.from=gamma
bundle.tags_only=yes
core.db_name=widgetopolis
core.engine=pg
core.extension=ddl
core.mysql.client=/opt/local/mysql/bin/mysql
core.mysql.username=root
core.pg.client=/opt/local/pgsql/bin/psql
core.pg.host=localhost
core.pg.username=postgres
core.sql_dir=migrations
core.sqlite.client=/opt/local/bin/sqlite3
revert.to=gamma
"
]], 'Should have emitted the merged config';
@emit = ();

CONTEXT: {
    local $ENV{SQITCH_SYSTEM_CONFIG} = file qw(t sqitch.conf);
    local $ENV{SQITCH_USER_CONFIG} = undef;
    $sqitch->config->load;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        list   => 1,
    }), 'Create system config list command';
    ok $cmd->execute, 'List the system config';
    is_deeply \@emit, [[
    "bundle.dest_dir=_build/sql
bundle.from=gamma
bundle.tags_only=yes
core.db_name=widgetopolis
core.engine=pg
core.extension=ddl
core.pg.client=/usr/local/pgsql/bin/psql
core.pg.username=theory
core.sql_dir=migrations
revert.to=gamma
"
    ]], 'Should have emitted the system config list';
    @emit = ();

    $ENV{SQITCH_USER_CONFIG} = file qw(t user.conf);
    $sqitch->config->load;
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user   => 1,
        list   => 1,
    }), 'Create user config list command';
    ok $cmd->execute, 'List the user config';
    is_deeply \@emit, [[
        "core.mysql.client=/opt/local/mysql/bin/mysql
core.mysql.username=root
core.pg.client=/opt/local/pgsql/bin/psql
core.pg.host=localhost
core.pg.username=postgres
core.sqlite.client=/opt/local/bin/sqlite3
"
    ]],  'Should only have emitted the user config list';
    @emit = ();
}

CONTEXT: {
    # What happens when there is no config file?
    local $ENV{SQITCH_SYSTEM_CONFIG} = 'NONEXISTENT';
    local $ENV{SQITCH_USER_CONFIG} = undef;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        list   => 1,
    }), 'Create system config list command with no file';
    ok $cmd->execute, 'List the system config';
    is_deeply \@emit, [], 'Nothing should have been emitted';

    $ENV{SQITCH_USER_CONFIG} = 'NONEXISTENT';
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user => 1,
        list   => 1,
    }), 'Create user config list command with no file';
    ok $cmd->execute, 'List the user config';
    is_deeply \@emit, [], 'Nothing should have been emitted';
}

##############################################################################
# Test set().
my $file = 'testconfig.conf';
$mock->mock(file => $file);
END { unlink $file }

ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    set    => 1,
}), 'Create system config set command';
ok $cmd->execute('core.foo' => 'bar'), 'Write core.foo';
is_deeply read_config($cmd->file), {'core.foo' => 'bar' },
    'The property should have been written';

# Write another property.
ok $cmd->execute('core.engine' => 'funky'), 'Write core.engine';
is_deeply read_config($cmd->file), {'core.foo' => 'bar', 'core.engine' => 'funky' },
    'Both settings should be saved';

# Write a sub-propery.
ok $cmd->execute('core.pg.user' => 'theory'), 'Write core.pg.user';
is_deeply read_config($cmd->file), {
    'core.foo'     => 'bar',
    'core.engine'  => 'funky',
    'core.pg.user' => 'theory',
}, 'Both sections should be saved';

##############################################################################
# Test add().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    add    => 1,
}), 'Create system config add command';
ok $cmd->execute('core.foo' => 'baz'), 'Add to core.foo';
is_deeply read_config($cmd->file), {
    'core.foo'     => ['bar', 'baz'],
    'core.engine'  => 'funky',
    'core.pg.user' => 'theory',
}, 'The value should have been added to the property';

##############################################################################
# Test unset().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    unset  => 1,
}), 'Create system config unset command';

ok $cmd->execute('core.pg.user'), 'Unset core.pg.user';
is_deeply read_config($cmd->file), {
    'core.foo'    => ['bar', 'baz'],
    'core.engine' => 'funky',
}, 'core.pg.user should be gone';
ok $cmd->execute('core.engine'), 'Unset core.engine';
is_deeply read_config($cmd->file), {
    'core.foo'    => ['bar', 'baz'],
}, 'core.foo should have been removed';

throws_ok { $cmd->execute('core.foo') } qr/FAIL/,
    'Should get failure trying to delete multivalue key';
is_deeply \@fail, ['Cannot unset key with multiple values'],
    'And it should have show the proper error message';

##############################################################################
# Test unset().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch    => $sqitch,
    unset_all => 1,
}), 'Create system config unset-all command';

ok $cmd->execute('core.foo'), 'Unset-all core.foo';
is_deeply read_config($cmd->file), {}, 'core.foo should have been removed';

##############################################################################
# Test edit().
my @sys;
my $ret = 1;
$mock->mock(do_system => sub { shift; @sys = @_; return $ret });
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    edit   => 1,
}), 'Create system config edit command';
ok $cmd->execute, 'Execute the edit comand';
is_deeply \@sys, [$sqitch->editor, $cmd->file],
    'The editor should have been run';

$ret = 0;
throws_ok { $cmd->execute } qr/FAIL/, 'Should fail on system failure';
is_deeply \@sys, [$sqitch->editor, $cmd->file],
    'The editor should have been run again';

sub read_config {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}
