#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 240;
#use Test::More 'no_plan';
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Test::NoWarnings;
use Path::Class;
use File::Path qw(remove_tree);

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

ok my $sqitch = App::Sqitch->new, 'Load a sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'config',
    config  => $sqitch->config,
}), 'App::Sqitch::Command::config', 'Config command';

isa_ok $cmd, 'App::Sqitch::Command', 'Config command';
can_ok $cmd, qw(file action context get get_all get_regexp set add unset unset_all list edit);

is_deeply [$cmd->options], [qw(
    file|config-file|f=s
    user
    system
    int
    bool
    num
    get
    get-all
    get-regexp
    add
    unset
    unset-all
    rename-section
    remove-section
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

# Test for multiple type specifications.
throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    bool   => 1,
    num    => 1,
}) } qr/USAGE/, 'Construct with bool and num';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get error for multiple types';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    int    => 1,
    num    => 1,
})} qr/USAGE/, 'Construct with int and num';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get another error for multiple types';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    int    => 1,
    bool   => 1,
})} qr/USAGE/, 'Construct with int and bool';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get a third error for multiple types';

throws_ok { App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    int    => 1,
    bool   => 1,
    num    => 1,
})} qr/USAGE/, 'Construct with int, num, and bool';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get one last error for multiple types';

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
    [qw(edit add list get_regexp)],
    [qw(edit add list unset_all)],
    [qw(edit add list get_all unset_all)],
    [qw(edit list remove_section)],
    [qw(edit list remove_section rename_section)],
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
my @unfound;
$mock->mock(unfound => sub { shift; @unfound = @_; die "UNFOUND @_" });
my @set;
$mock->mock(set => sub { shift; @set = @_; return 1 });
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    system  => 1,
    config  => $sqitch->config,
}), 'Create config set command';

ok $cmd->execute(qw(foo bar)), 'Execute the set command';
is_deeply \@set, [qw(foo bar)], 'The set method should have been called';
$mock->unmock('set');

##############################################################################
# Test get().
chdir 't';
$ENV{SQITCH_USER_CONFIG} = 'user.conf';
$sqitch->config->load;
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

# Make sure int data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get     => 1,
    int     => 1,
}), 'Create config get int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an int should fail';

# Make sure num data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get     => 1,
    num     => 1,
}), 'Create config get num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [[1.1]],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an num should fail';

# Make sure bool data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get     => 1,
    bool    => 1,
}), 'Create config get bool command';

throws_ok { $cmd->execute('revert.count') } qr/FAIL/,
    'Should get failure for invalid bool int';
throws_ok { $cmd->execute('revert.revision') } qr/FAIL/,
    'Should get failure for invalid bool num';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [['true']],
    'Should have emitted bundle.tags_only a bool';
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
    @emit = @fail = @unfound = ();

    throws_ok { $cmd->execute('core.pg.host') } qr/UNFOUND/,
        'Attempt to get core.pg.host should fail';
    is_deeply \@emit, [], 'Nothing should have been emitted';
    is_deeply \@unfound, [], 'Nothing should have been output on failure';

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
    throws_ok { $cmd->execute('core.engine') } qr/UNFOUND/,
        'Should fail when no system config file';
    is_deeply \@unfound, [], 'Nothing should have been emitted';

    local $ENV{SQITCH_USER_CONFIG} = 'NONEXISTENT';
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user => 1,
        get    => 1,
    }), 'Create another user config get command';
    ok !-f $cmd->file, 'There should be no user config file';
    throws_ok { $cmd->execute('core.engine') } qr/UNFOUND/,
        'Should fail when no user config file';
    is_deeply \@unfound, [], 'Nothing should have been emitted';
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
bundle.tags_only=true
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
revert.count=2
revert.revision=1.1
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
bundle.tags_only=true
core.db_name=widgetopolis
core.engine=pg
core.extension=ddl
core.pg.client=/usr/local/pgsql/bin/psql
core.pg.username=theory
core.sql_dir=migrations
revert.count=2
revert.revision=1.1
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
# Test get with regex.
$ENV{SQITCH_USER_CONFIG} = $file;
$sqitch->config->load;
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    get    => 1,
}), 'Create system config add command';
ok $cmd->execute('core.engine', 'funk'), 'Get core.engine with regex';
is_deeply \@emit, [['funky']], 'Should have emitted value';
@emit = ();

ok $cmd->execute('core.foo', 'z$'), 'Get core.foo with regex';
is_deeply \@emit, [['baz']], 'Should have emitted value';
@emit = ();

throws_ok { $cmd->execute('core.foo', 'x$') } qr/UNFOUND/,
    'Attempt to get core.foo with non-matching regex should fail';
is_deeply \@emit, [], 'Nothing should have been emitted';
is_deeply \@unfound, [], 'Nothing should have been output on failure';

##############################################################################
# Test get_all().
@emit = ();
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_all => 1,
}), 'Create system config get_all command';
ok $cmd->execute('core.engine'), 'Call get_all on core.engine';
is_deeply \@emit, [['funky']], 'The engine should have been emitted';
@emit = ();

ok $cmd->execute('core.engine', 'funk'), 'Get all core.engine with regex';
is_deeply \@emit, [['funky']], 'Should have emitted value';
@emit = ();

ok $cmd->execute('core.foo'), 'Call get_all on core.foo';
is_deeply \@emit, [["bar\nbaz"]], 'Both foos should have been emitted';
@emit = ();

ok $cmd->execute('core.foo', '^ba'), 'Call get_all on core.foo with regex';
is_deeply \@emit, [["bar\nbaz"]], 'Both foos should have been emitted';
@emit = ();

ok $cmd->execute('core.foo', 'z$'), 'Call get_all on core.foo with limiting regex';
is_deeply \@emit, [["baz"]], 'Only the one foo should have been emitted';
@emit = ();

throws_ok { $cmd->execute('core.foo', 'x$') } qr/UNFOUND/,
    'Attempt to get_all core.foo with non-matching regex should fail';
is_deeply \@emit, [], 'Nothing should have been emitted';
is_deeply \@unfound, [], 'Nothing should have been output on failure';

# Make sure int data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_all => 1,
    int     => 1,
}), 'Create config get_all int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an int should fail';

# Make sure num data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_all => 1,
    num     => 1,
}), 'Create config get_all num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [[1.1]],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an num should fail';

# Make sure bool data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_all => 1,
    bool    => 1,
}), 'Create config get_all bool command';

throws_ok { $cmd->execute('revert.count') } qr/FAIL/,
    'Should get failure for invalid bool int';
throws_ok { $cmd->execute('revert.revision') } qr/FAIL/,
    'Should get failure for invalid bool num';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [[$Config::GitLike::VERSION > 1.08 ? 'true' : 1]],
    'Should have emitted bundle.tags_only a bool';
@emit = ();

##############################################################################
# Test get_regexp().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_regexp => 1,
}), 'Create system config get_regexp command';
ok $cmd->execute('core\\..+'), 'Call get_regexp on core\\..+';
is_deeply \@emit, [[q{core.db_name=widgetopolis
core.engine=funky
core.extension=ddl
core.foo=[bar, baz]
core.pg.client=/usr/local/pgsql/bin/psql
core.pg.user=theory
core.pg.username=theory
core.sql_dir=migrations}
]], 'Should match all core options';
@emit = ();

ok $cmd->execute('core\\.pg\\..+'), 'Call get_regexp on core\\.pg\\..+';
is_deeply \@emit, [[q{core.pg.client=/usr/local/pgsql/bin/psql
core.pg.user=theory
core.pg.username=theory}
]], 'Should match all core.pg options';
@emit = ();

ok $cmd->execute('core\\.pg\\..+', 'theory$'),
    'Call get_regexp on core\\.pg\\..+ and value regex';
is_deeply \@emit, [[q{core.pg.user=theory
core.pg.username=theory}
]], 'Should match all core.pg options that match';
@emit = ();

throws_ok { $cmd->execute('core\\.pg\\..+', 'x$') } qr/UNFOUND/,
    'Attempt to get_regexp core.foo with non-matching regex should fail';
is_deeply \@emit, [], 'Nothing should have been emitted';
is_deeply \@unfound, [], 'Nothing should have been output on failure';

# Make sure int data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_regexp => 1,
    int     => 1,
}), 'Create config get_regexp int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [['revert.count=2']],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [['revert.revision=1']],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an int should fail';

# Make sure num data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_regexp => 1,
    num     => 1,
}), 'Create config get_regexp num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [['revert.count=2']],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [['revert.revision=1.1']],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } qr/FAIL/,
    'Get bundle.tags_only as an num should fail';

# Make sure bool data type works.
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    get_regexp => 1,
    bool    => 1,
}), 'Create config get_regexp bool command';

throws_ok { $cmd->execute('revert.count') } qr/FAIL/,
    'Should get failure for invalid bool int';
throws_ok { $cmd->execute('revert.revision') } qr/FAIL/,
    'Should get failure for invalid bool num';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [['bundle.tags_only=' . ($Config::GitLike::VERSION > 1.08 ? 'true' : 1)]],
    'Should have emitted bundle.tags_only a bool';
@emit = ();

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
    'core.foo'  => ['bar', 'baz'],
}, 'core.engine should have been removed';

throws_ok { $cmd->execute('core.foo') } qr/FAIL/,
    'Should get failure trying to delete multivalue key';
is_deeply \@fail, ['Cannot unset key with multiple values'],
    'And it should have show the proper error message';

ok $cmd->execute('core.foo', 'z$'), 'Unset core.foo with a regex';
is_deeply read_config($cmd->file), {
    'core.foo' => 'bar',
}, 'The core.foo "baz" value should have been removed';

##############################################################################
# Test unset_all().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch    => $sqitch,
    unset_all => 1,
}), 'Create system config unset-all command';

$cmd->add('core.foo', 'baz');
ok $cmd->execute('core.foo'), 'Unset-all core.foo';
is_deeply read_config($cmd->file), {}, 'core.foo should have been removed';

# Test handling of multiple value.
$cmd->add('core.foo', 'bar');
$cmd->add('core.foo', 'baz');
$cmd->add('core.foo', 'yo');

ok $cmd->execute('core.foo', '^ba'), 'Unset-all core.foo with regex';
is_deeply read_config($cmd->file), {
    'core.foo' => 'yo',
}, 'core.foo should have one value left';


##############################################################################
# Test rename_section().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch         => $sqitch,
    rename_section => 1,
}), 'Create system config rename-section command';
ok $cmd->execute('core', 'funk'), 'Rename "core" to "funk"';
is_deeply read_config($cmd->file), {
    'funk.foo' => 'yo',
}, 'core.foo should have become funk.foo';

throws_ok { $cmd->execute('foo') } qr/USAGE/, 'Should fail with no new name';
is_deeply \@usage, ['Wrong number of arguments'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('', 'bar') } qr/USAGE/, 'Should fail with bad old name';
is_deeply \@usage, ['Wrong number of arguments'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('baz', '') } qr/USAGE/, 'Should fail with bad new name';
is_deeply \@usage, ['Wrong number of arguments'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('foo', 'bar') } qr/FAIL/, 'Should fail with invalid section';
is_deeply \@fail, ['No such section!'],
    'Message should be in the fail call';

##############################################################################
# Test remove_section().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch         => $sqitch,
    remove_section => 1,
}), 'Create system config remove-section command';
ok $cmd->execute('funk'), 'Remove "func" section';
is_deeply read_config($cmd->file), {},
    'The "funk" section should be gone';

throws_ok { $cmd->execute() } qr/USAGE/, 'Should fail with no name';
is_deeply \@usage, ['Wrong number of arguments'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('bar') } qr/FAIL/, 'Should fail with invalid name';
is_deeply \@fail, ['No such section!'],
    'Message should be in the fail call';

##############################################################################
# Test errors with multiple values.

throws_ok { $cmd->get('core.foo', '.') } qr/FAIL/,
    'Should fail fetching multi-value key';
is_deeply \@fail, [qq{More then one value for the key "core.foo"}],
    'The error should be sent to fail()';

$cmd->add('core.foo', 'hi');
$cmd->add('core.foo', 'bye');
throws_ok { $cmd->set('core.foo', 'hi') } qr/FAIL/,
    'Should fail setting multi-value key';
is_deeply \@fail, ['Cannot overwrite multiple values with a single value'],
    'The error should be sent to fail()';

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

##############################################################################
# Make sure we can write to a file in a directory.
my $path = file qw(t config.tmp test.conf);
$mock->mock(file => $path);
END { remove_tree +File::Spec->catdir(qw(t config.tmp)) }
ok $sqitch = App::Sqitch->new, 'Load a new sqitch object';
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    user   => 1,
    set    => 1,
}), 'Create system config set command with subdirectory config file path';
ok $cmd->execute('my.foo', 'hi'), 'Set "my.foo" in subdirectory config file';
is_deeply read_config($cmd->file), {'my.foo' => 'hi' },
    'The file should have been written';

sub read_config {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}
