#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 133;
#use Test::More 'no_plan';
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Test::NoWarnings;

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

##############################################################################
# Test the user config.
require File::HomeDir;
my $home = File::HomeDir->my_home;
is $CLASS->_user_config_root, Path::Class::dir($home)->subdir('.sqitch'),
    'The default user config root should be correct';

USER: {
    local $ENV{SQITCH_USER_CONFIG_ROOT} = 't';
    is $CLASS->_user_config_root, $ENV{SQITCH_USER_CONFIG_ROOT},
        '_user_config_root should use \$ENV{SQITCH_USER_CONFIG_ROOT}';
    is_deeply $CLASS->_load_config, $config_ini,
        'Should load config.ini for user config';
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

##############################################################################
# Test the system config.
is $CLASS->_system_config_root, Path::Class::dir($Config::Config{prefix}, 'etc'),
    'The default system config path should be in $prefix/etc';
SYSTEM: {
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = 't';
    is $CLASS->_system_config_root, $ENV{SQITCH_SYSTEM_CONFIG_ROOT},
        '_system_config_root should use \$ENV{SQITCH_SYSTEM_CONFIG_ROOT}';
    is_deeply $CLASS->_load_config, $sqitch_ini,
        'Should load sqitch.ini for system config';
}

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
$ENV{SQITCH_USER_CONFIG_ROOT} = File::Spec->curdir;
is_deeply $CLASS->_load_config, $both_ini,
    'Should merge both ini files with both present';

##############################################################################
# Test the editor.
EDITOR: {
    local $ENV{EDITOR} = 'edd';
    my $sqitch = App::Sqitch->new({editor => 'emacz' });
    is $sqitch->editor, 'emacz', 'editor should use use parameter';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'edd', 'editor should use $EDITOR';

    local $ENV{SQITCH_EDITOR} = 'vimz';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'vimz', 'editor should prefer $SQITCH_EDITOR';

    delete $ENV{SQITCH_EDITOR};
    delete $ENV{EDITOR};
    local $^O = 'NotWin32';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'vi', 'editor fall back on vi when not Windows';

    $^O = 'MSWin32';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'notepad.exe', 'editor fall back on notepad on Windows';
}

##############################################################################
# Test the command.
ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
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
    unset
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
is $cmd->file, File::Spec->catfile(File::Spec->curdir, 'sqitch.ini'),
    'Default config file should be local config file';
is $cmd->action, 'set', 'Default action should be "set"';
is $cmd->context, 'project', 'Default context should be "project"';

# Test user file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    user    => 1,
}), 'App::Sqitch::Command::config', 'User config command';

is $cmd->file, File::Spec->catfile($sqitch->_user_config_root, 'config.ini'),
    'User config file should be in user config root';

# Test system file name.
isa_ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    system  => 1,
}), 'App::Sqitch::Command::config', 'System config command';

is $cmd->file, File::Spec->catfile($Config::Config{prefix}, qw(etc sqitch.ini)),
    "System config file should be in $Config::Config{prefix}/etc";

##############################################################################
# Test property parsing.
my @fail;
$mock->mock(fail => sub { shift; @fail = @_; die "FAIL @_" });

is_deeply [$cmd->_parse_key('foo.bar')], [qw(foo bar)],
    'Parse foo.bar';
is_deeply [$cmd->_parse_key('foo.bar.baz')], [qw(foo.bar baz)],
    'Parse foo.bar.baz';
is_deeply [$cmd->_parse_key('foo.bar.baz.yo')], [qw(foo.bar.baz yo)],
    'Parse foo.bar.baz.yo';

# Test errors.
throws_ok { $cmd->_parse_key('foo') } qr/FAIL/, 'Parse foo';
is_deeply \@fail, [qq{Property key does not contain a section: "foo"}],
    'Should die for invalid key';
throws_ok { $cmd->_parse_key('')} qr/USAGE/, 'Parse nothing';
is_deeply \@usage, ['Wrong number of arguments'],
    'Should get usage for missing key';

##############################################################################
# Test file locking.
LOCKS: {
    ok my $fh = $cmd->_open_to_read('config.t'), 'Open ourselves';
    isa_ok $fh, 'GLOB', 'The read file handle';

    # Lock a file.
    END { unlink '.locktest' };
    ok $fh = $cmd->_open_to_write('.locktest'), 'Open .locktest to write';
    isa_ok $fh, 'GLOB', 'The write file handle';

    # Try to lock it again.
    throws_ok { $cmd->_open_to_write('.locktest') } qr/^FAIL/,
        'Should get an exception trying to get a second lock';
    is_deeply \@fail, ["Cannot lock config file .locktest"],
        'Should have lock failure error';

    # Try to get a sharelock.
    throws_ok { $cmd->_open_to_read('.locktest') } qr/^FAIL/,
        'Should get an exception trying to get a share lock';
    is_deeply \@fail, ['Config file .locktest locked'],
        'Should have share lock failure error';
}

##############################################################################
# Test execute().
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
# Test _config_for_reading().
ok $sqitch = $CLASS->new({ config => $CLASS->_load_config }),
    'Load config into Sqtich';

ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
}), 'Create default config command';
is $cmd->_config_for_reading, $sqitch->config,
    'The config for reading should be the combined config';

CONTEXT: {
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = File::Spec->curdir;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
    }), 'Create system config command';
    is_deeply $cmd->_config_for_reading, $cmd->read_config,
        'The config for reading should be the system config';

    local $ENV{SQITCH_USER_CONFIG_ROOT} = File::Spec->curdir;
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user => 1,
    }), 'Create user config command';
    is_deeply $cmd->_config_for_reading, $cmd->read_config,
        'The config for reading should be the user config';
}

##############################################################################
# Test get().
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

CONTEXT: {
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = File::Spec->curdir;
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

    local $ENV{SQITCH_USER_CONFIG_ROOT} = File::Spec->curdir;
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
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = 'NONEXISTENT';
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        get    => 1,
    }), 'Create another system config get command';
    ok !-f $cmd->file, 'There should be no system config file';
    throws_ok { $cmd->execute('core.engine') } qr/FAIL/,
        'Should fail when no system config file';
    is_deeply \@fail, [], 'Nothing should have been emitted';

    local $ENV{SQITCH_USER_CONFIG_ROOT} = 'NONEXISTENT';
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
ok $cmd = App::Sqitch::Command::config->new({
    sqitch  => $sqitch,
    list    => 1,
}), 'Create config list command';
ok $cmd->execute, 'Execute the list action';
is_deeply \@emit, [
    [ "bundle.dest_dir="     => "_build/sql" ],
    [ "bundle.from="         => "gamma" ],
    [ "bundle.tags_only="    => "yes" ],
    [ "core.db_name="        => "widgetopolis" ],
    [ "core.engine="         => "pg" ],
    [ "core.extension="      => "ddl" ],
    [ "core.sql_dir="        => "migrations" ],
    [ "core.mysql.client="   => "/opt/local/mysql/bin/mysql" ],
    [ "core.mysql.username=" => "root" ],
    [ "core.pg.client="      => "/usr/local/pgsql/bin/psql" ],
    [ "core.pg.host="        => "localhost" ],
    [ "core.pg.username="    => "theory" ],
    [ "core.sqlite.client="  => "/opt/local/bin/sqlite3" ],
    [ "revert.to="           => "gamma" ],
], 'Should have emitted the merged config';
@emit = ();

CONTEXT: {
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = File::Spec->curdir;
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        list   => 1,
    }), 'Create system config list command';
    ok $cmd->execute, 'List the system config';
    is_deeply \@emit,[
        [ "bundle.dest_dir="  => "_build/sql" ],
        [ "bundle.from="      => "gamma" ],
        [ "bundle.tags_only=" => "yes" ],
        [ "core.db_name="     => "widgetopolis" ],
        [ "core.engine="      => "pg" ],
        [ "core.extension="   => "ddl" ],
        [ "core.sql_dir="     => "migrations" ],
        [ "core.pg.client="   => "/usr/local/pgsql/bin/psql" ],
        [ "core.pg.username=" => "theory" ],
        [ "revert.to="        => "gamma" ],
    ], 'Should have emitted the system config list';
    @emit = ();

    local $ENV{SQITCH_USER_CONFIG_ROOT} = File::Spec->curdir;
    ok $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        user => 1,
        list   => 1,
    }), 'Create user config list command';
    ok $cmd->execute, 'List the user config';
    is_deeply \@emit, [
        [ "core.mysql.client="   => "/opt/local/mysql/bin/mysql" ],
        [ "core.mysql.username=" => "root" ],
        [ "core.pg.client="      => "/opt/local/pgsql/bin/psql" ],
        [ "core.pg.host="        => "localhost" ],
        [ "core.pg.username="    => "postgres" ],
        [ "core.sqlite.client="  => "/opt/local/bin/sqlite3" ],
    ],  'Should have emitted the user config list';
    @emit = ();
}

CONTEXT: {
    # What happens when there is no config file?
    local $ENV{SQITCH_SYSTEM_CONFIG_ROOT} = 'NONEXISTENT';
    ok my $cmd = App::Sqitch::Command::config->new({
        sqitch => $sqitch,
        system => 1,
        list   => 1,
    }), 'Create system config list command with no file';
    ok $cmd->execute, 'List the system config';
    is_deeply \@emit, [], 'Nothing should have been emitted';

    local $ENV{SQITCH_USER_CONFIG_ROOT} = 'NONEXISTENT';
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
my $file = 'testconfig.ini';
$mock->mock(file => $file);
END { unlink $file }

ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    set    => 1,
}), 'Create system config set command';
ok $cmd->execute('core.foo' => 'bar'), 'Write core.foo';
is_deeply $cmd->read_config, {core => { foo => 'bar' }},
    'The property should have been written';

# Write another property.
ok $cmd->execute('core.engine' => 'funky'), 'Write core.engine';
is_deeply $cmd->read_config, {core => { foo => 'bar', engine => 'funky' }},
    'Both settings should be saved';

# Write a sub-propery.
ok $cmd->execute('core.pg.user' => 'theory'), 'Write core.pg.user';
is_deeply $cmd->read_config, {
    core => { foo => 'bar', engine => 'funky' },
    'core.pg' => {user => 'theory' },
}, 'Both sections should be saved';

##############################################################################
# Test unset().
ok $cmd = App::Sqitch::Command::config->new({
    sqitch => $sqitch,
    unset  => 1,
}), 'Create system config unset command';

ok $cmd->execute('core.pg.user'), 'Unset core.pg.user';
is_deeply $cmd->read_config, {
    core => { foo => 'bar', engine => 'funky' },
    'core.pg' => {},
}, 'core.pg.user should be gone';
ok $cmd->execute('core.foo'), 'Unset core.foo';
is_deeply $cmd->read_config, {
    core => { engine => 'funky' },
    'core.pg' => {},
}, 'core.foo should have been removed';

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
