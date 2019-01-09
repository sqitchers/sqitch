#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 282;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::NoWarnings;
use File::Copy;
use Path::Class;
use File::Temp 'tempdir';
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::engine';

##############################################################################
# Set up a test directory and config file.
my $tmp_dir = tempdir CLEANUP => 1;

File::Copy::copy file(qw(t engine.conf))->stringify, "$tmp_dir"
    or die "Cannot copy t/engine.conf to $tmp_dir: $!\n";
File::Copy::copy file(qw(t engine sqitch.plan))->stringify, "$tmp_dir"
    or die "Cannot copy t/engine/sqitch.plan to $tmp_dir: $!\n";
chdir $tmp_dir;
my $config = TestConfig->from(local => 'engine.conf');
my $psql = 'psql' . (App::Sqitch::ISWIN ? '.exe' : '');

##############################################################################
# Load an engine command and test the basics.
ok my $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'engine',
    config  => $config,
}), $CLASS, 'Engine command';

can_ok $cmd, qw(
    options
    configure
    execute
    list
    add
    set_target
    set_registry
    set_client
    remove
    rm
    show
    update_config
);

is_deeply [$CLASS->options], [qw(
    verbose|v+
    target=s
    plan-file=s
    registry=s
    client=s
    extension=s
    top-dir=s
    dir|d=s%
)], 'Options should be correct';

# Check default property values.
is_deeply $CLASS->configure({}, {}), { properties => {}},
    'Default config should contain empty properties';

# Make sure configure ignores config file.
is_deeply $CLASS->configure({ foo => 'bar'}, { verbose => 1 }),
    { verbose => 1, properties => {} },
    'configure() should ignore config file';

ok my $conf = $CLASS->configure({}, {
    top_dir             => 'top',
    plan_file           => 'my.plan',
    registry            => 'bats',
    client              => 'cli',
    extension           => 'ddl',
    target              => 'db:pg:foo',
    dir => {
        deploy          => 'dep',
        revert          => 'rev',
        verify          => 'ver',
        reworked        => 'wrk',
        reworked_deploy => 'rdep',
        reworked_revert => 'rrev',
        reworked_verify => 'rver',
    },
}), 'Get full config';

is_deeply $conf->{properties}, {
        top_dir             => 'top',
        plan_file           => 'my.plan',
        registry            => 'bats',
        client              => 'cli',
        extension           => 'ddl',
        target              => 'db:pg:foo',
        deploy_dir          => 'dep',
        revert_dir          => 'rev',
        verify_dir          => 'ver',
        reworked_dir        => 'wrk',
        reworked_deploy_dir => 'rdep',
        reworked_revert_dir => 'rrev',
        reworked_verify_dir => 'rver',
}, 'Should have properties';
isa_ok $conf->{properties}{$_}, 'Path::Class::File', "$_ file attribute" for qw(
    plan_file
);
isa_ok $conf->{properties}{$_}, 'Path::Class::Dir', "$_ directory attribute" for (
    'top_dir',
    'reworked_dir',
    map { ($_, "reworked_$_") } qw(deploy_dir revert_dir verify_dir)
);

# Make sure invalid directories are ignored.
throws_ok { $CLASS->new($CLASS->configure({}, {
    dir => { foo => 'bar' },
})) } 'App::Sqitch::X',  'Should fail on invalid directory name';
is $@->ident, 'engine', 'Invalid directory ident should be "engine"';
is $@->message, __x(
    'Unknown directory name: {prop}',
    prop => 'foo',
), 'The invalid directory messsage should be correct';

throws_ok { $CLASS->new($CLASS->configure({}, {
    dir => { foo => 'bar', cavort => 'ha' },
})) } 'App::Sqitch::X',  'Should fail on invalid directory names';
is $@->ident, 'engine', 'Invalid directories ident should be "engine"';
is $@->message, __x(
    'Unknown directory names: {props}',
    props => 'cavort, foo',
), 'The invalid properties messsage should be correct';

##############################################################################
# Test list().
ok $cmd->list, 'Run list()';
is_deeply +MockOutput->get_emit, [['mysql'], ['pg'], ['sqlite']],
    'The list of engines should have been output';

# Make it verbose.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, verbose => 1 }),
    $CLASS, 'Verbose engine';
ok $cmd->list, 'Run verbose list()';
is_deeply +MockOutput->get_emit, [
    ["mysql\tdb:mysql://root@/foo"],
    ["pg\tdb:pg:try"],
    ["sqlite\twidgets"]
], 'The list of engines and their targets should have been output';

##############################################################################
# Test add().
MISSINGARGS: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->add } qr/USAGE/,
        'No name arg to add() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should die on existing key.
throws_ok { $cmd->add('pg') } 'App::Sqitch::X',
    'Should get error for existing engine';
is $@->ident, 'engine', 'Existing engine error ident should be "engine"';
is $@->message, __x(
    'Engine "{engine}" already exists',
    engine => 'pg'
), 'Existing engine error message should be correct';

# Now add a new engine.
dir_not_exists_ok $_ for qw(deploy revert verify);
ok $cmd->add('vertica'), 'Add engine "vertica"';
dir_exists_ok $_ for qw(deploy revert verify);
$config->load;
is $config->get(key => 'engine.vertica.target'), 'db:vertica:',
    'Engine "test" target should have been set';
for my $key (qw(
    client
    registry
    top_dir
    plan_file
    deploy_dir
    revert_dir
    verify_dir
    extension
)) {
    is $config->get(key => "engine.test.$key"), undef,
        qq{Engine "test" should have no $key set};
}

# Should die on target that doesn't match the engine.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { target => 'db:sqlite:' },
}), $CLASS, 'Engine with target property';
throws_ok { $cmd->add('firebird' ) } 'App::Sqitch::X',
    'Should get error for engine/target mismatch';
is $@->ident, 'engine', 'Target mismatch ident should be "engine"';
is $@->message, __x(
    'Cannot assign URI using engine "{new}" to engine "{old}"',
    new => 'sqlite',
    old => 'firebird',
), 'Target mismatch message should be correct';

# Try all the properties.
my %props = (
    target              => 'db:firebird:foo',
    client              => 'poo',
    registry            => 'reg',
    top_dir             => dir('top'),
    plan_file           => file('my.plan'),
    deploy_dir          => dir('dep'),
    revert_dir          => dir('rev'),
    verify_dir          => dir('ver'),
    reworked_dir        => dir('r'),
    reworked_deploy_dir => dir('r/d'),
    extension           => 'ddl',
);
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { %props },
}), $CLASS, 'Engine with all properties';
file_not_exists_ok 'my.plan';
dir_not_exists_ok dir $_ for qw(top/deploy top/revert top/verify r/d r/revert r/verify);
ok $cmd->add('firebird'), 'Add engine "firebird"';
dir_exists_ok dir $_ for qw(top/deploy top/revert top/verify r/d r/revert r/verify);
file_exists_ok 'my.plan';
$config->load;
while (my ($k, $v) = each %props) {
    is $config->get(key => "engine.firebird.$k"), $v,
        qq{Engine "firebird" should have $k set};
}

##############################################################################
# Test alter().
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
}), $CLASS, 'Engine with no properties';

MISSINGARGS: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->alter } qr/USAGE/,
        'No name arg to add() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

throws_ok { $cmd->alter('nonexistent' ) } 'App::Sqitch::X',
    'Should get error from alter for nonexistent engine';
is $@->ident, 'engine', 'Nonexistent engine error ident should be "engine"';
is $@->message, __x(
    'Unknown engine "{engine}"',
    engine => 'nonexistent'
), 'Nonexistent engine error message should be correct';

# Should die on missing key.
throws_ok { $cmd->alter('oracle') } 'App::Sqitch::X',
    'Should get error for missing engine';
is $@->ident, 'engine', 'Missing engine error ident should be "engine"';
is $@->message, __x(
    'Missing Engine "{engine}"; use "{command}" to add it',
    engine  => 'oracle',
    command => 'add oracle db:oracle:',
), 'Missing engine error message should be correct';

# Try all the properties.
%props = (
    target              => 'db:firebird:bar',
    client              => 'argh',
    registry            => 'migrations',
    top_dir             => dir('fb'),
    plan_file           => file('fb.plan'),
    deploy_dir          => dir('fb/dep'),
    revert_dir          => dir('fb/rev'),
    verify_dir          => dir('fb/ver'),
    reworked_dir        => dir('fb/r'),
    reworked_deploy_dir => dir('fb/r/d'),
    extension           => 'fbsql',
);
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { %props },
}), $CLASS, 'Engine with more properties';
ok $cmd->alter('firebird'), 'Alter engine "firebird"';
$config->load;
while (my ($k, $v) = each %props) {
    is $config->get(key => "engine.firebird.$k"), $v,
        qq{Engine "firebird" should have $k set};
}

# Try changing the top directory.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { top_dir => dir 'pg' },
}), $CLASS, 'Engine with new top_dir property';
dir_not_exists_ok dir $_ for qw(pg pg/deploy pg/revert pg/verify);
ok $cmd->alter('pg'), 'Alter engine "pg"';
dir_exists_ok dir $_ for qw(pg pg/deploy pg/revert pg/verify);
$config->load;
is $config->get(key => 'engine.pg.top_dir'), 'pg',
    'The pg top_dir should have been set';

# An attempt to alter a missing engine should show the target if in props.
throws_ok { $cmd->alter('oracle') } 'App::Sqitch::X',
    'Should again get error for missing engine';
is $@->ident, 'engine', 'Missing engine error ident should still be "engine"';
is $@->message, __x(
    'Missing Engine "{engine}"; use "{command}" to add it',
    engine  => 'oracle',
    command => 'add oracle db:oracle:',
), 'Missing engine error message should include target property';

# Should die on target mismatch engine.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { target => 'db:sqlite:' },
}), $CLASS, 'Engine with target property';
throws_ok { $cmd->alter('firebird' ) } 'App::Sqitch::X',
    'Should get error for engine/target mismatch';
is $@->ident, 'engine', 'Target mismatch ident should be "engine"';
is $@->message, __x(
    'Cannot assign URI using engine "{new}" to engine "{old}"',
    new => 'sqlite',
    old => 'firebird',
), 'Target mismatch message should be correct';

##############################################################################
# Test set_target().
MISSINGARGS: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->set_target } qr/USAGE/,
        'No name arg to set_target() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';

    @args = ();
    throws_ok { $cmd->set_target('foo') } qr/USAGE/,
        'No target arg to set_target() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should get an error if the engine does not exist.
throws_ok { $cmd->set_target('nonexistent', 'db:pg:' ) } 'App::Sqitch::X',
    'Should get error for nonexistent engine';
is $@->ident, 'engine', 'Nonexistent engine error ident should be "engine"';
is $@->message, __x(
    'Unknown engine "{engine}"',
    engine => 'nonexistent'
), 'Nonexistent engine error message should be correct';

# Set one that exists.
ok $cmd->set_target('pg', 'db:pg:newtarget'), 'Set new target';
$config->load;
is $config->get(key => 'engine.pg.target'), 'db:pg:newtarget',
    'Engine "pg" should have new target';

# Make sure the target is a database target.
ok $cmd->set_target('pg', 'postgres:stuff'), 'Set new target';
$config->load;
is $config->get(key => 'engine.pg.target'), 'db:postgres:stuff',
    'Engine "pg" should have new DB target';

# Make sure we die for an unknown target.
throws_ok { $cmd->set_target('pg', 'unknown') } 'App::Sqitch::X',
    'Should get an error for an unknown target';
is $@->ident, 'engine', 'Nonexistent target error ident should be "engine"';
is $@->message, __x(
    'Unknown target "{target}"',
    target => 'unknown'
), 'Nonexistent target error message should be correct';

##############################################################################
# Test other set_* methods
for my $key (keys %props) {
    next if $key =~ /^reworked/;
    my $meth = "set_$key";
    MISSINGARGS: {
        # Test handling of no name.
        my $mock = Test::MockModule->new($CLASS);
        my @args;
        $mock->mock(usage => sub { @args = @_; die 'USAGE' });
        throws_ok { $cmd->$meth } qr/USAGE/,
            "No name arg to $meth() should yield usage";
        is_deeply \@args, [$cmd], 'No args should be passed to usage';

        @args = ();
        throws_ok { $cmd->$meth('foo') } qr/USAGE/,
            "No $key arg to $meth() should yield usage";
        is_deeply \@args, [$cmd], 'No args should be passed to usage';
    }

    # Should get an error if the engine does not exist.
    throws_ok { $cmd->$meth('nonexistent', 'widgets' ) } 'App::Sqitch::X',
        'Should get error for nonexistent engine';
    is $@->ident, 'engine', 'Nonexistent engine error ident should be "engine"';
    is $@->message, __x(
        'Unknown engine "{engine}"',
        engine => 'nonexistent'
    ), 'Nonexistent engine error message should be correct';

    # Set one that exists.
    ok $cmd->$meth('pg', 'widgets'), 'Set new $key';
    $config->load;
    is $config->get(key => "engine.pg.$key"), 'widgets',
        qq{Engine "pg" should have new $key};
}

##############################################################################
# Test remove.
MISSINGARGS: {
    # Test handling of no names.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->remove } qr/USAGE/,
        'No name args to remove() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should get an error if the engine does not exist.
throws_ok { $cmd->remove('nonexistent', 'existant' ) } 'App::Sqitch::X',
    'Should get error for nonexistent engine';
is $@->ident, 'engine', 'Nonexistent engine error ident should be "engine"';
is $@->message, __x(
    'Unknown engine "{engine}"',
    engine => 'nonexistent'
), 'Nonexistent engine error message should be correct';

# Remove one that exists.
ok $cmd->remove('mysql'), 'Remove';
$config->load;
is $config->get(key => "engine.mysql.target"), undef,
    qq{Engine "mysql" should now be gone};

##############################################################################
# Test show.
ok $cmd->show, 'Run show()';
is_deeply +MockOutput->get_emit, [
    ['firebird'], ['pg'], ['sqlite'], ['vertica']
], 'Show with no names should emit the list of engines';

# Try one engine.
ok $cmd->show('sqlite'), 'Show sqlite';
is_deeply +MockOutput->get_emit, [
    ['* sqlite'],
    ['    ', 'Target:        ', 'widgets'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', '/usr/sbin/sqlite3'],
    ['    ', 'Top Directory: ', '.'],
    ['    ', 'Plan File:     ', 'foo.plan'],
    ['    ', 'Extension:     ', 'sql'],
    ['    ', 'Script Directories:'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
    ['    ', 'Reworked Script Directories:'],
    ['    ', '  Reworked:    ', '.'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
], 'The full "sqlite" engine should have been shown';

# Try multiples.
ok $cmd->set_client(vertica => 'vsql.exe'), 'Set vertica client';
$config->load;
ok $cmd->show(qw(sqlite vertica firebird)), 'Show three engines';
is_deeply +MockOutput->get_emit, [
    ['* sqlite'],
    ['    ', 'Target:        ', 'widgets'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', '/usr/sbin/sqlite3'],
    ['    ', 'Top Directory: ', '.'],
    ['    ', 'Plan File:     ', 'foo.plan'],
    ['    ', 'Extension:     ', 'sql'],
    ['    ', 'Script Directories:'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
    ['    ', 'Reworked Script Directories:'],
    ['    ', '  Reworked:    ', '.'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
    ['* vertica'],
    ['    ', 'Target:        ', 'db:vertica:'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', 'vsql.exe'],
    ['    ', 'Top Directory: ', '.'],
    ['    ', 'Plan File:     ', 'sqitch.plan'],
    ['    ', 'Extension:     ', 'sql'],
    ['    ', 'Script Directories:'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
    ['    ', 'Reworked Script Directories:'],
    ['    ', '  Reworked:    ', '.'],
    ['    ', '  Deploy:      ', 'deploy'],
    ['    ', '  Revert:      ', 'revert'],
    ['    ', '  Verify:      ', 'verify'],
    ['* firebird'],
    ['    ', 'Target:        ', 'db:firebird:bar'],
    ['    ', 'Registry:      ', 'migrations'],
    ['    ', 'Client:        ', 'argh'],
    ['    ', 'Top Directory: ', 'fb'],
    ['    ', 'Plan File:     ', 'fb.plan'],
    ['    ', 'Extension:     ', 'fbsql'],
    ['    ', 'Script Directories:'],
    ['    ', '  Deploy:      ', dir 'fb/dep'],
    ['    ', '  Revert:      ', dir 'fb/rev'],
    ['    ', '  Verify:      ', dir 'fb/ver'],
    ['    ', 'Reworked Script Directories:'],
    ['    ', '  Reworked:    ', dir 'fb/r'],
    ['    ', '  Deploy:      ', dir 'fb/r/d'],
    ['    ', '  Revert:      ', dir 'fb/r/revert'],
    ['    ', '  Verify:      ', dir 'fb/r/verify'],
], 'All three engines should have been shown';

##############################################################################
# Test execute().
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch }), $CLASS, 'Simple engine';
for my $spec (
    [ undef,          'list'   ],
    [ 'list'                   ],
    [ 'add'                    ],
    [ 'set-target'             ],
    [ 'set-registry'           ],
    [ 'set-client'             ],
    [ 'remove'                 ],
    [ 'rm',          'remove'  ],
    [ 'rename'                 ],
    [ 'show'                   ],
) {
    my ($arg, $meth) = @{ $spec };
    $meth //= $arg;
    $meth =~ s/-/_/g;
    my $mocker = Test::MockModule->new($CLASS);
    my @args;
    $mocker->mock($meth => sub { @args = @_ });
    ok $cmd->execute($spec->[0]), "Execute " . ($spec->[0] // 'undef');
    is_deeply \@args, [$cmd], "$meth() should have been called";

    # Make sure args are passed.
    ok $cmd->execute($spec->[0], qw(pg db:pg:)),
        "Execute " . ($spec->[0] // 'undef') . ' with args';
    is_deeply \@args, [$cmd, qw(pg db:pg:)],
        "$meth() should have been passed args";
}

# Make sure an invalid action dies with a usage statement.
MISSINGARGS: {
    # Test handling of no names.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->execute('nonexistent') } qr/USAGE/,
        'Should get an exception for a nonexistent action';
    is_deeply \@args, [$cmd, __x(
        'Unknown action "{action}"',
        action => 'nonexistent',
    )], 'Nonexistent action message should be passed to usage';
}

##############################################################################
# Test update_config.
$config->group_set($config->local_file, [
    {key => 'core.mysql.target',   value => 'widgets'   },
    {key => 'core.mysql.client',   value => 'mysql.exe' },
    {key => 'core.mysql.registry', value => 'spliff'    },
    {key => 'core.mysql.host',     value => 'localhost' },
    {key => 'core.mysql.port',     value => 1234        },
    {key => 'core.mysql.username', value => 'fred'      },
    {key => 'core.mysql.password', value => 'barb'      },
    {key => 'core.mysql.db_name',  value => 'ouch'      },
]);
$cmd->sqitch->config->load;
my $core = $cmd->sqitch->config->get_section(section => 'core.mysql');
ok $cmd->update_config, 'Update the config';
$cmd->sqitch->config->load;
is_deeply $cmd->sqitch->config->get_section(section => 'core.mysql'), $core,
    'The core.mysql config should still be present';
is_deeply $cmd->sqitch->config->get_section(section => 'engine.mysql'), {
    target => 'widgets',
    client => 'mysql.exe',
    registry => 'spliff',
}, 'MySQL config should have been rewritten without deprecated keys';

# Try with no target.
$config->rename_section(
    from     => 'engine.mysql',
    filename => $config->local_file,
);
$config->group_set($config->local_file, [
    {key => 'core.mysql.target',   value => undef       },
    {key => 'core.mysql.client',   value => 'mysql.exe' },
    {key => 'core.mysql.registry', value => 'spliff'    },
    {key => 'core.mysql.host',     value => 'localhost' },
    {key => 'core.mysql.port',     value => 1234        },
    {key => 'core.mysql.username', value => 'fred'      },
    {key => 'core.mysql.password', value => 'barb'      },
    {key => 'core.mysql.db_name',  value => 'ouch'      },
]);
$cmd->sqitch->config->load;
$core = $cmd->sqitch->config->get_section(section => 'core.mysql');
ok $cmd->update_config, 'Update the config again';
$cmd->sqitch->config->load;
is_deeply $cmd->sqitch->config->get_section(section => 'core.mysql'), $core,
    'The core.mysql config should again remain';
is_deeply $cmd->sqitch->config->get_section(section => 'engine.mysql'), {
    target => 'db:mysql://fred:barb@localhost:1234/ouch',
    client => 'mysql.exe',
    registry => 'spliff',
}, 'MySQL config should have been rewritten with an integrated target';

# Try with no deprecated keys.
$config->rename_section(
    from     => 'engine.mysql',
    filename => $config->local_file,
);
$config->group_set($config->local_file, [
    {key => 'core.mysql.client',   value => 'mysql.exe' },
    {key => 'core.mysql.registry', value => 'spliff'    },
    {key => 'core.mysql.host',     value => undef       },
    {key => 'core.mysql.port',     value => undef       },
    {key => 'core.mysql.username', value => undef       },
    {key => 'core.mysql.password', value => undef       },
    {key => 'core.mysql.db_name',  value => undef       },
]);
$cmd->sqitch->config->load;
$core = $cmd->sqitch->config->get_section(section => 'core.mysql');
ok $cmd->update_config, 'Update the config again';
$cmd->sqitch->config->load;
is_deeply $cmd->sqitch->config->get_section(section => 'core.mysql'), $core,
    'The core.mysql config should again remain';
is_deeply $cmd->sqitch->config->get_section(section => 'engine.mysql'), {
    target => 'db:mysql:',
    client => 'mysql.exe',
    registry => 'spliff',
}, 'MySQL config should have been rewritten with a default target';
