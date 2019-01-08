#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 344;
#use Test::More 'no_plan';
use File::Spec;
use Test::MockModule;
use Test::Exception;
use Test::NoWarnings;
use Path::Class;
use File::Path qw(remove_tree);
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use TestConfig;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::Command::config';
    use_ok $CLASS or die;
}

my $config = TestConfig->new;
ok my $sqitch = App::Sqitch->new(config => $config), 'Load a sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'config',
    config  => $config,
}), 'App::Sqitch::Command::config', 'Config command';

isa_ok $cmd, 'App::Sqitch::Command', 'Config command';
can_ok $cmd, qw(file action context get get_all get_regex set add unset unset_all list edit);

is_deeply [$cmd->options], [qw(
    file|config-file|f=s
    local
    user|global
    system
    int
    bool
    bool-or-int
    num
    get
    get-all
    get-regex|get-regexp
    add
    replace-all
    unset
    unset-all
    rename-section
    remove-section
    list|l
    edit|e
)], 'Options should be configured';

##############################################################################
# Test configure errors.
my $mock = Test::MockModule->new('App::Sqitch::Command::config');
my @usage;
$mock->mock(usage => sub { shift; @usage = @_; die 'USAGE' });

# Test for multiple config file specifications.
throws_ok { $CLASS->configure( $sqitch->config, {
    user    => 1,
    system  => 1,
}) } qr/USAGE/, 'Construct with user and system';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get error for multiple config files';

throws_ok { $CLASS->configure( $sqitch->config, {
    user  => 1,
    local => 1,
}) } qr/USAGE/, 'Construct with user and local';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get error for multiple config files';

throws_ok { $CLASS->configure( $sqitch->config, {
    file   => 't/sqitch.ini',
    system => 1,
})} qr/USAGE/, 'Construct with file and system';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get another error for multiple config files';

throws_ok { $CLASS->configure( $sqitch->config, {
    file   => 't/sqitch.ini',
    user   => 1,
})} qr/USAGE/, 'Construct with file and user';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get a third error for multiple config files';

throws_ok { $CLASS->configure( $sqitch->config, {
    file   => 't/sqitch.ini',
    user   => 1,
    system => 1,
})} qr/USAGE/, 'Construct with file, system, and user';
is_deeply \@usage, ['Only one config file at a time.'],
    'Should get one last error for multiple config files';

# Test for multiple type specifications.
throws_ok { $CLASS->configure( $sqitch->config, {
    bool   => 1,
    num    => 1,
}) } qr/USAGE/, 'Construct with bool and num';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get error for multiple types';

throws_ok { $CLASS->configure( $sqitch->config, {
    sqitch => $sqitch,
    int    => 1,
    num    => 1,
})} qr/USAGE/, 'Construct with int and num';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get another error for multiple types';

throws_ok { $CLASS->configure( $sqitch->config, {
    int    => 1,
    bool   => 1,
})} qr/USAGE/, 'Construct with int and bool';
is_deeply \@usage, ['Only one type at a time.'],
    'Should get a third error for multiple types';

throws_ok { $CLASS->configure( $sqitch->config, {
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
    [qw(edit add list get_regex)],
    [qw(edit add list unset_all)],
    [qw(edit add list get_all unset_all)],
    [qw(edit list remove_section)],
    [qw(edit list remove_section rename_section)],
) {
    throws_ok { $CLASS->configure( $sqitch->config, {
        map { $_ => 1 } @{ $spec }
    })} qr/USAGE/, 'Construct with ' . join ' & ' => @{ $spec };
    is_deeply \@usage, ['Only one action at a time.'],
        'Should get error for multiple actions';
}

##############################################################################
# Test context.
is $cmd->file, $sqitch->config->dir_file,
    'Default context should be local context';
is $cmd->action, undef, 'Default action should be undef';
is $cmd->context, undef, 'Default context should be undef';

# Test local file name.
is_deeply $CLASS->configure( $sqitch->config, {
    local    => 1,
}), {
    context => 'local',
}, 'Local context should be local';

# Test user file name.
is_deeply $CLASS->configure( $sqitch->config, {
    user    => 1,
}), {
    context => 'user',
}, 'User context should be user';

# Test system file name.
is_deeply $CLASS->configure( $sqitch->config, {
    system    => 1,
}), {
    context => 'system',
}, 'System context should be system';

##############################################################################
# Test execute().
my @fail;
$mock->mock(fail => sub { shift; @fail = @_; die "FAIL @_" });
my @set;
$mock->mock(set => sub { shift; @set = @_; return 1 });
my @get;
$mock->mock(get => sub { shift; @get = @_; return 1 });
my @get_all;
$mock->mock(get_all => sub { shift; @get_all = @_; return 1 });
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    context => 'system',
}), 'Create config set command';

ok $cmd->execute(qw(foo bar)), 'Execute the set command';
is_deeply \@set, [qw(foo bar)], 'The set method should have been called';
ok $cmd->execute(qw(foo)), 'Execute the get command';
is_deeply \@get, [qw(foo)], 'The get method should have been called';

ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
}), 'Create config get_all command';
$cmd->execute('boy.howdy');
is_deeply \@get_all, ['boy.howdy'],
    'An action with a dash should have triggered a method with an underscore';
$mock->unmock(qw(set get get_all));

##############################################################################
# Test get().
chdir 't';
$config = TestConfig->from(local => 'sqitch.conf', user => 'user.conf');
$sqitch = App::Sqitch->new(config => $config);
my @emit;
$mock->mock(emit => sub { shift; push @emit => [@_] });
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
}), 'Create config get command';

ok $cmd->execute('core.engine'), 'Get core.engine';
is_deeply \@emit, [['pg']], 'Should have emitted the merged core.engine';
@emit = ();

ok $cmd->execute('engine.pg.registry'), 'Get engine.pg.registry';
is_deeply \@emit, [['meta']], 'Should have emitted the merged engine.pg.registry';
@emit = ();

ok $cmd->execute('engine.pg.client'), 'Get engine.pg.client';
is_deeply \@emit, [['/usr/local/pgsql/bin/psql']],
    'Should have emitted the merged engine.pg.client';
@emit = ();

# Make sure the key is required.
throws_ok { $cmd->get } qr/USAGE/, 'Should get usage for missing get key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing get key should trigger a usage message';
throws_ok { $cmd->get('') } qr/USAGE/, 'Should get usage for invalid get key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid get key should trigger a usage message';

# Make sure int data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
    type    => 'int',
}), 'Create config get int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an int should fail';
is $@->ident, 'config', 'Int cast exception ident should be "config"';

# Make sure num data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
    type    => 'num',
}), 'Create config get num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [[1.1]],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an num should fail';
is $@->ident, 'config', 'Num cast exception ident should be "config"';

# Make sure bool data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
    type    => 'bool',
}), 'Create config get bool command';

throws_ok { $cmd->execute('revert.count') } 'App::Sqitch::X',
    'Should get failure for invalid bool int';
is $@->ident, 'config', 'Bool int cast exception ident should be "config"';
throws_ok { $cmd->execute('revert.revision') } 'App::Sqitch::X',
    'Should get failure for invalid bool num';
is $@->ident, 'config', 'Bool num cast exception ident should be "config"';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [['true']],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

# Make sure bool-or-int data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
    type    => 'bool-or-int',
}), 'Create config get bool-or-int command';

ok $cmd->execute('revert.count'), 'Get revert.count as bool-or-int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count as an int';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as bool-or-int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool-or-int';
is_deeply \@emit, [['true']],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

chdir File::Spec->updir;

CONTEXT: {
    my $config = TestConfig->from(system => file qw(t sqitch.conf));
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'system',
        action  => 'get',
    }), 'Create system config get command';
    ok $cmd->execute('core.engine'), 'Get system core.engine';
    is_deeply \@emit, [['pg']], 'Should have emitted the system core.engine';
    @emit = ();

    ok $cmd->execute('engine.pg.client'), 'Get system engine.pg.client';
    is_deeply \@emit, [['/usr/local/pgsql/bin/psql']],
        'Should have emitted the system engine.pg.client';
    @emit = @fail = ();

    throws_ok { $cmd->execute('engine.pg.host') } 'App::Sqitch::X',
        'Attempt to get engine.pg.host should fail';
    is $@->ident, 'config', 'Error ident should be "config"';
    is $@->message, '', 'Error Message should be empty';
    is $@->exitval, 1, 'Error exitval should be 1';
    is_deeply \@emit, [], 'Nothing should have been emitted';

    $config = TestConfig->from(
        system => file(qw(t sqitch.conf)),
        user   => file(qw(t user.conf)),
    );
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'user',
        action  => 'get',
    }), 'Create user config get command';
    @emit = ();

    ok $cmd->execute('engine.pg.registry'), 'Get user engine.pg.registry';
    is_deeply \@emit, [['meta']], 'Should have emitted the user engine.pg.registry';
    @emit = ();

    ok $cmd->execute('engine.pg.client'), 'Get user engine.pg.client';
    is_deeply \@emit, [['/opt/local/pgsql/bin/psql']],
        'Should have emitted the user engine.pg.client';
    @emit = ();

    $config = TestConfig->from(
        system => file(qw(t sqitch.conf)),
        user   => file(qw(t user.conf)),
        local  => file(qw(t local.conf)),
    );
    $sqitch->config->load;
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'local',
        action  => 'get',
    }), 'Create local config get command';
    @emit = ();

    ok $cmd->execute('engine.pg.target'), 'Get local engine.pg.target';
    is_deeply \@emit, [['mydb']], 'Should have emitted the local engine.pg.target';
    @emit = ();

    ok $cmd->execute('core.engine'), 'Get local core.engine';
    is_deeply \@emit, [['pg']], 'Should have emitted the local core.engine';
    @emit = ();
}

CONTEXT: {
    # What happens when there is no config file?
    my $config = TestConfig->new;
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'system',
        action  => 'get',
    }), 'Create another system config get command';
    ok !-f $cmd->file, 'There should be no system config file';
    throws_ok { $cmd->execute('core.engine') } 'App::Sqitch::X',
        'Should fail when no system config file';
    is $@->ident, 'config', 'Error ident should be "config"';
    is $@->message, '', 'Error Message should be empty';
    is $@->exitval, 1, 'Error exitval should be 1';

    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'user',
        action  => 'get',
    }), 'Create another user config get command';
    ok !-f $cmd->file, 'There should be no user config file';
    throws_ok { $cmd->execute('core.engine') } 'App::Sqitch::X',
        'Should fail when no user config file';
    is $@->ident, 'config', 'Error ident should be "config"';
    is $@->message, '', 'Error Message should be empty';
    is $@->exitval, 1, 'Error exitval should be 1';

    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'local',
        action  => 'get',
    }), 'Create another local config get command';
    ok !-f $cmd->file, 'There should be no local config file';
    throws_ok { $cmd->execute('core.engine') } 'App::Sqitch::X',
        'Should fail when no local config file';
    is $@->ident, 'config', 'Error ident should be "config"';
    is $@->message, '', 'Error Message should be empty';
    is $@->exitval, 1, 'Error exitval should be 1';
}

##############################################################################
# Test list().
$config = TestConfig->from(
    system => file(qw(t sqitch.conf)),
    user   => file(qw(t user.conf)),
    local  => file(qw(t local.conf)),
);
$sqitch = App::Sqitch->new(config => $config);
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'list',
}), 'Create config list command';
ok $cmd->execute, 'Execute the list action';
is_deeply \@emit, [[
    'bundle.dest_dir=_build/sql
bundle.from=gamma
bundle.tags_only=true
core.engine=pg
core.extension=ddl
core.pager=less -r
core.top_dir=migrations
core.uri=https://github.com/sqitchers/sqitch/
engine.firebird.client=/opt/firebird/bin/isql
engine.firebird.registry=meta
engine.mysql.client=/opt/local/mysql/bin/mysql
engine.mysql.registry=meta
engine.pg.client=/opt/local/pgsql/bin/psql
engine.pg.registry=meta
engine.pg.target=mydb
engine.sqlite.client=/opt/local/bin/sqlite3
engine.sqlite.registry=meta
engine.sqlite.target=devdb
revert.count=2
revert.revision=1.1
revert.to=gamma
target.devdb.uri=db:sqlite:
target.mydb.plan_file=t/plans/dependencies.plan
target.mydb.uri=db:pg:mydb
user.email=michael@example.com
user.name=Michael Stonebraker
'
]], 'Should have emitted the merged config';
@emit = ();

CONTEXT: {
    $config = TestConfig->from(system => file qw(t sqitch.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'system',
        action  => 'list',
    }), 'Create system config list command';
    ok $cmd->execute, 'List the system config';
    is_deeply \@emit, [[
        'bundle.dest_dir=_build/sql
bundle.from=gamma
bundle.tags_only=true
core.engine=pg
core.extension=ddl
core.pager=less -r
core.top_dir=migrations
core.uri=https://github.com/sqitchers/sqitch/
engine.pg.client=/usr/local/pgsql/bin/psql
revert.count=2
revert.revision=1.1
revert.to=gamma
'
    ]], 'Should have emitted the system config list';
    @emit = ();

    $config = TestConfig->from(
        system => file(qw(t sqitch.conf)),
        user   => file(qw(t user.conf)),
    );
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'user',
        action  => 'list',
    }), 'Create user config list command';
    ok $cmd->execute, 'List the user config';
    is_deeply \@emit, [[
        'engine.firebird.client=/opt/firebird/bin/isql
engine.firebird.registry=meta
engine.mysql.client=/opt/local/mysql/bin/mysql
engine.mysql.registry=meta
engine.pg.client=/opt/local/pgsql/bin/psql
engine.pg.registry=meta
engine.pg.target=db:pg://postgres@localhost/thingies
engine.sqlite.client=/opt/local/bin/sqlite3
engine.sqlite.registry=meta
engine.sqlite.target=db:sqlite:my.db
user.email=michael@example.com
user.name=Michael Stonebraker
'
    ]],  'Should only have emitted the user config list';
    @emit = ();

    $config = TestConfig->from(
        system => file(qw(t sqitch.conf)),
        user   => file(qw(t user.conf)),
        local  => file(qw(t local.conf)),
    );
    $sqitch = App::Sqitch->new(config => $config);
    ok $cmd = $CLASS->new({
        sqitch  => $sqitch,
        context => 'local',
        action  => 'list',
    }), 'Create local config list command';
    ok $cmd->execute, 'List the local config';
    is_deeply \@emit, [[
        'core.engine=pg
engine.pg.target=mydb
engine.sqlite.target=devdb
target.devdb.uri=db:sqlite:
target.mydb.plan_file=t/plans/dependencies.plan
target.mydb.uri=db:pg:mydb
'
    ]],  'Should only have emitted the local config list';
    @emit = ();
}

# What happens when there is no config file?
$config = TestConfig->from;
$sqitch = App::Sqitch->new(config => $config);
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    context => 'system',
    action  => 'list',
}), 'Create system config list command with no file';
ok $cmd->execute, 'List the system config';
is_deeply \@emit, [], 'Nothing should have been emitted';

ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    context => 'user',
    action  => 'list',
}), 'Create user config list command with no file';
ok $cmd->execute, 'List the user config';
is_deeply \@emit, [], 'Nothing should have been emitted';

##############################################################################
# Test set().
my $file = 'testconfig.conf';
$mock->mock(file => $file);
END { unlink $file }

ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
}), 'Create system config set command';
ok $cmd->execute('core.foo' => 'bar'), 'Write core.foo';
is_deeply read_config($cmd->file), {'core.foo' => 'bar' },
    'The property should have been written';

# Write another property.
ok $cmd->execute('core.engine' => 'funky'), 'Write core.engine';
is_deeply read_config($cmd->file), {'core.foo' => 'bar', 'core.engine' => 'funky' },
    'Both settings should be saved';

# Write a sub-propery.
ok $cmd->execute('engine.pg.user' => 'theory'), 'Write engine.pg.user';
is_deeply read_config($cmd->file), {
    'core.foo'     => 'bar',
    'core.engine'  => 'funky',
    'engine.pg.user' => 'theory',
}, 'Both sections should be saved';

# Make sure the key is required.
throws_ok { $cmd->set } qr/USAGE/, 'Should set usage for missing set key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing set key should trigger a usage message';
throws_ok { $cmd->set('') } qr/USAGE/, 'Should set usage for invalid set key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid set key should trigger a usage message';

# Make sure the value is required.
throws_ok { $cmd->set('foo.bar') } qr/USAGE/, 'Should set usage for missing set value';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing set value should trigger a usage message';

##############################################################################
# Test add().
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'add',
}), 'Create system config add command';
ok $cmd->execute('core.foo' => 'baz'), 'Add to core.foo';
is_deeply read_config($cmd->file), {
    'core.foo'     => ['bar', 'baz'],
    'core.engine'  => 'funky',
    'engine.pg.user' => 'theory',
}, 'The value should have been added to the property';

# Make sure the key is required.
throws_ok { $cmd->add } qr/USAGE/, 'Should add usage for missing add key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing add key should trigger a usage message';
throws_ok { $cmd->add('') } qr/USAGE/, 'Should add usage for invalid add key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid add key should trigger a usage message';

# Make sure the value is required.
throws_ok { $cmd->add('foo.bar') } qr/USAGE/, 'Should add usage for missing add value';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing add value should trigger a usage message';

##############################################################################
# Test get with regex.
$config = TestConfig->from(user => $file);
$sqitch = App::Sqitch->new(config => $config);
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get',
}), 'Create system config add command';
ok $cmd->execute('core.engine', 'funk'), 'Get core.engine with regex';
is_deeply \@emit, [['funky']], 'Should have emitted value';
@emit = ();

ok $cmd->execute('core.foo', 'z$'), 'Get core.foo with regex';
is_deeply \@emit, [['baz']], 'Should have emitted value';
@emit = ();

throws_ok { $cmd->execute('core.foo', 'x$') } 'App::Sqitch::X',
    'Attempt to get core.foo with non-matching regex should fail';
is $@->ident, 'config', 'Error ident should be "config"';
is $@->message, '', 'Error Message should be empty';
is $@->exitval, 1, 'Error exitval should be 1';
is_deeply \@emit, [], 'Nothing should have been emitted';

##############################################################################
# Test get_all().
@emit = ();
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
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

throws_ok { $cmd->execute('core.foo', 'x$') } 'App::Sqitch::X',
    'Attempt to get_all core.foo with non-matching regex should fail';
is $@->ident, 'config', 'Error ident should be "config"';
is $@->message, '', 'Error Message should be empty';
is $@->exitval, 1, 'Error exitval should be 1';
is_deeply \@emit, [], 'Nothing should have been emitted';

# Make sure the key is required.
throws_ok { $cmd->get_all } qr/USAGE/, 'Should get_all usage for missing get_all key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing get_all key should trigger a usage message';
throws_ok { $cmd->get_all('') } qr/USAGE/, 'Should get_all usage for invalid get_all key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid get_all key should trigger a usage message';

# Make sure int data type works.
$config = TestConfig->from(local => file qw(t sqitch.conf));
$sqitch = App::Sqitch->new(config => $config);
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
    type    => 'int',
}), 'Create config get_all int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an int should fail';
is $@->ident, 'config', 'Int cast exception ident should be "config"';

# Make sure num data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
    type    => 'num',
}), 'Create config get_all num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [[1.1]],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an num should fail';
is $@->ident, 'config', 'Num cast exception ident should be "config"';

# Make sure bool data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
    type    => 'bool',
}), 'Create config get_all bool command';

throws_ok { $cmd->execute('revert.count') } 'App::Sqitch::X',
    'Should get failure for invalid bool int';
is $@->ident, 'config', 'Bool int cast exception ident should be "config"';
throws_ok { $cmd->execute('revert.revision') } 'App::Sqitch::X',
    'Should get failure for invalid bool num';
is $@->ident, 'config', 'Num int cast exception ident should be "config"';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [[$Config::GitLike::VERSION > 1.08 ? 'true' : 1]],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

# Make sure bool-or-int data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_all',
    type    => 'bool-or-int',
}), 'Create config get_all bool-or-int command';

ok $cmd->execute('revert.count'), 'Get revert.count as bool-or-int';
is_deeply \@emit, [[2]],
    'Should have emitted the revert count as an int';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as bool-or-int';
is_deeply \@emit, [[1]],
    'Should have emitted the revert revision as an int';
@emit = ();

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool-or-int';
is_deeply \@emit, [[$Config::GitLike::VERSION > 1.08 ? 'true' : 1]],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

##############################################################################
# Test get_regex().
$config = TestConfig->from(local => $file, user => file qw(t sqitch.conf));
$sqitch = App::Sqitch->new(config => $config);
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_regex',
}), 'Create system config get_regex command';
ok $cmd->execute('core\\..+'), 'Call get_regex on core\\..+';
is_deeply \@emit, [[q{core.engine=funky
core.extension=ddl
core.foo=[bar, baz]
core.pager=less -r
core.top_dir=migrations
core.uri=https://github.com/sqitchers/sqitch/}
]], 'Should match all core options';
@emit = ();

ok $cmd->execute('engine\\.pg\\..+'), 'Call get_regex on engine\\.pg\\..+';
is_deeply \@emit, [[q{engine.pg.client=/usr/local/pgsql/bin/psql
engine.pg.user=theory}
]], 'Should match all engine.pg options';
@emit = ();

ok $cmd->execute('engine\\.pg\\..+', 'theory$'),
    'Call get_regex on engine\\.pg\\..+ and value regex';
is_deeply \@emit, [[q{engine.pg.user=theory}
]], 'Should match all engine.pg options that match';
@emit = ();

throws_ok { $cmd->execute('engine\\.pg\\..+', 'x$') } 'App::Sqitch::X',
    'Attempt to get_regex core.foo with non-matching regex should fail';
is $@->ident, 'config', 'Error ident should be "config"';
is $@->message, '', 'Error Message should be empty';
is $@->exitval, 1, 'Error exitval should be 1';
is_deeply \@emit, [], 'Nothing should have been emitted';

# Make sure the key is required.
throws_ok { $cmd->get_regex } qr/USAGE/, 'Should get_regex usage for missing get_regex key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing get_regex key should trigger a usage message';
throws_ok { $cmd->get_regex('') } qr/USAGE/, 'Should get_regex usage for invalid get_regex key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid get_regex key should trigger a usage message';

# Make sure int data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_regex',
    type    => 'int',
}), 'Create config get_regex int command';

ok $cmd->execute('revert.count'), 'Get revert.count as int';
is_deeply \@emit, [['revert.count=2']],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as int';
is_deeply \@emit, [['revert.revision=1']],
    'Should have emitted the revert revision as an int';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an int should fail';
is $@->ident, 'config', 'Int cast exception ident should be "config"';

# Make sure num data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_regex',
    type    => 'num',
}), 'Create config get_regexp num command';

ok $cmd->execute('revert.count'), 'Get revert.count as num';
is_deeply \@emit, [['revert.count=2']],
    'Should have emitted the revert count';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as num';
is_deeply \@emit, [['revert.revision=1.1']],
    'Should have emitted the revert revision as an num';
@emit = ();

throws_ok { $cmd->execute('bundle.tags_only') } 'App::Sqitch::X',
    'Get bundle.tags_only as an num should fail';
is $@->ident, 'config', 'Num cast exception ident should be "config"';

# Make sure bool data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_regex',
    type    => 'bool',
}), 'Create config get_regex bool command';

throws_ok { $cmd->execute('revert.count') } 'App::Sqitch::X',
    'Should get failure for invalid bool int';
is $@->ident, 'config', 'Bool int cast exception ident should be "config"';
throws_ok { $cmd->execute('revert.revision') } 'App::Sqitch::X',
    'Should get failure for invalid bool num';
is $@->ident, 'config', 'Num int cast exception ident should be "config"';

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool';
is_deeply \@emit, [['bundle.tags_only=' . ($Config::GitLike::VERSION > 1.08 ? 'true' : 1)]],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

# Make sure int data type works.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'get_regex',
    type    => 'bool-or-int',
}), 'Create config get_regex bool-or-int command';

ok $cmd->execute('revert.count'), 'Get revert.count as bool-or-int';
is_deeply \@emit, [['revert.count=2']],
    'Should have emitted the revert count as an int';
@emit = ();

ok $cmd->execute('revert.revision'), 'Get revert.revision as bool-or-int';
is_deeply \@emit, [['revert.revision=1']],
    'Should have emitted the revert revision as an int';
@emit = ();

ok $cmd->execute('bundle.tags_only'), 'Get bundle.tags_only as bool-or-int';
is_deeply \@emit, [['bundle.tags_only=' . ($Config::GitLike::VERSION > 1.08 ? 'true' : 1)]],
    'Should have emitted bundle.tags_only as a bool';
@emit = ();

##############################################################################
# Test unset().
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'unset',
}), 'Create system config unset command';

ok $cmd->execute('engine.pg.user'), 'Unset engine.pg.user';
is_deeply read_config($cmd->file), {
    'core.foo'    => ['bar', 'baz'],
    'core.engine' => 'funky',
}, 'engine.pg.user should be gone';
ok $cmd->execute('core.engine'), 'Unset core.engine';
is_deeply read_config($cmd->file), {
    'core.foo'  => ['bar', 'baz'],
}, 'core.engine should have been removed';

throws_ok { $cmd->execute('core.foo') } 'App::Sqitch::X',
    'Should get failure trying to delete multivalue key';
is $@->ident, 'config', 'Multiple value exception ident should be "config"';
is $@->message, __ 'Cannot unset key with multiple values',
    'And it should have the proper error message';

ok $cmd->execute('core.foo', 'z$'), 'Unset core.foo with a regex';
is_deeply read_config($cmd->file), {
    'core.foo' => 'bar',
}, 'The core.foo "baz" value should have been removed';

# Make sure the key is required.
throws_ok { $cmd->unset } qr/USAGE/, 'Should unset usage for missing unset key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing unset key should trigger a usage message';
throws_ok { $cmd->unset('') } qr/USAGE/, 'Should unset usage for invalid unset key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid unset key should trigger a usage message';

##############################################################################
# Test unset_all().
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'unset_all',
}), 'Create system config unset_all command';

$cmd->add('core.foo', 'baz');
ok $cmd->execute('core.foo'), 'unset_all core.foo';
is_deeply read_config($cmd->file), {}, 'core.foo should have been removed';

# Test handling of multiple value.
$cmd->add('core.foo', 'bar');
$cmd->add('core.foo', 'baz');
$cmd->add('core.foo', 'yo');

ok $cmd->execute('core.foo', '^ba'), 'unset_all core.foo with regex';
is_deeply read_config($cmd->file), {
    'core.foo' => 'yo',
}, 'core.foo should have one value left';

# Make sure the key is required.
throws_ok { $cmd->unset_all } qr/USAGE/, 'Should unset_all usage for missing unset_all key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the missing unset_all key should trigger a usage message';
throws_ok { $cmd->unset_all('') } qr/USAGE/, 'Should unset_all usage for invalid unset_all key';
is_deeply \@usage, ['Wrong number of arguments.'],
    'And the invalid unset_all key should trigger a usage message';

##############################################################################
# Test replace_all.
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'replace_all',
}), 'Create system config replace_all command';

$cmd->add('core.bar', 'bar');
$cmd->add('core.bar', 'baz');
$cmd->add('core.bar', 'yo');

ok $cmd->execute('core.bar', 'hi'), 'Replace all core.bar';
is_deeply read_config($cmd->file), {
    'core.bar' => 'hi',
    'core.foo' => 'yo',
}, 'core.bar should have all its values with one value';

$cmd->add('core.foo', 'bar');
$cmd->add('core.foo', 'baz');
ok $cmd->execute('core.foo', 'ba', '^ba'), 'Replace all core.bar matching /^ba/';

is_deeply read_config($cmd->file), {
    'core.bar' => 'hi',
    'core.foo' => ['yo', 'ba'],
}, 'core.foo should have had the matching values replaced';

# Clean up.
$cmd->unset_all('core.bar');
$cmd->unset('core.foo', 'ba');

##############################################################################
# Test rename_section().
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'rename_section',
}), 'Create system config rename_section command';
ok $cmd->execute('core', 'funk'), 'Rename "core" to "funk"';
is_deeply read_config($cmd->file), {
    'funk.foo' => 'yo',
}, 'core.foo should have become funk.foo';

throws_ok { $cmd->execute('foo') } qr/USAGE/, 'Should fail with no new name';
is_deeply \@usage, ['Wrong number of arguments.'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('', 'bar') } qr/USAGE/, 'Should fail with bad old name';
is_deeply \@usage, ['Wrong number of arguments.'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('baz', '') } qr/USAGE/, 'Should fail with bad new name';
is_deeply \@usage, ['Wrong number of arguments.'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('foo', 'bar') } 'App::Sqitch::X',
    'Should fail with invalid section';
is $@->ident, 'config', 'Invalid section exception ident should be "config"';
is $@->message, __ 'No such section!',
    'Invalid section exception message should be set';

##############################################################################
# Test remove_section().
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'remove_section',
}), 'Create system config remove_section command';
ok $cmd->execute('funk'), 'Remove "func" section';
is_deeply read_config($cmd->file), {},
    'The "funk" section should be gone';

throws_ok { $cmd->execute() } qr/USAGE/, 'Should fail with no name';
is_deeply \@usage, ['Wrong number of arguments.'],
    'Message should be in the usage call';

throws_ok { $cmd->execute('bar') } 'App::Sqitch::X',
    'Should fail with invalid name';
is $@->ident, 'config', 'Invalid key name exception ident should be "config"';
is $@->message, __ 'No such section!', 'And the invalid key message should be set';

##############################################################################
# Test errors with multiple values.

throws_ok { $cmd->get('core.foo', '.') } 'App::Sqitch::X',
    'Should fail fetching multi-value key';
is $@->ident, 'config', 'Multi-value key exception ident should be "config"';
is $@->message, __x(
    'More then one value for the key "{key}"',
    key => 'core.foo',
), 'The multiple value error should be thrown';

$cmd->add('core.foo', 'hi');
$cmd->add('core.foo', 'bye');
throws_ok { $cmd->set('core.foo', 'hi') } 'App::Sqitch::X',
    'Should fail setting multi-value key';
is $@->ident, 'config', 'Mult-valkue key exception ident should be "config"';
is $@->message, __('Cannot overwrite multiple values with a single value'),
    'The multi-value key error should be thrown';

##############################################################################
# Test edit().
my $shell;
my $ret = 1;
$mock->mock(shell => sub { $shell = $_[1]; return $ret });
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
    action  => 'edit',
}), 'Create system config edit command';
ok $cmd->execute, 'Execute the edit comand';
is $shell, $sqitch->editor . ' ' . $sqitch->quote_shell($cmd->file),
    'The editor should have been run';

##############################################################################
# Make sure we can write to a file in a directory.
my $path = file qw(t config.tmp test.conf);
$mock->mock(file => $path);
END { remove_tree +File::Spec->catdir(qw(t config.tmp)) }
ok $sqitch = App::Sqitch->new, 'Load a new sqitch object';
ok $cmd = $CLASS->new({
    sqitch  => $sqitch,
}), 'Create system config set command with subdirectory config file path';
ok $cmd->execute('my.foo', 'hi'), 'Set "my.foo" in subdirectory config file';
is_deeply read_config($cmd->file), {'my.foo' => 'hi' },
    'The file should have been written';

sub read_config {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}
