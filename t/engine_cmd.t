#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 187;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Test::NoWarnings;
use File::Copy;
use Path::Class;
use File::Temp 'tempdir';
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

# Circumvent Config::Gitlike bug on Windows.
# https://rt.cpan.org/Ticket/Display.html?id=96670
$ENV{HOME} ||= '~';

my $CLASS = 'App::Sqitch::Command::engine';

##############################################################################
# Set up a test directory and config file.
my $tmp_dir = tempdir CLEANUP => 1;

File::Copy::copy file(qw(t engine.conf))->stringify, "$tmp_dir"
    or die "Cannot copy t/engine.conf to $tmp_dir: $!\n";
chdir $tmp_dir;
$ENV{SQITCH_CONFIG} = 'engine.conf';
my $psql = 'psql' . ($^O eq 'MSWin32' ? '.exe' : '');

##############################################################################
# Load a engine command and test the basics.
ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
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
);

is_deeply [$CLASS->options], [qw(
    set|s=s%
    verbose|v+
)], 'Options should be correct';

# Check default property values.
is_deeply $cmd->properties, {}, 'Default properties should be empty';

# Make sure configure ignores config file.
is_deeply $CLASS->configure({ foo => 'bar'}, { hi => 'there' }),
    { hi => 'there' },
    'configure() should ignore config file';

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
ok $cmd->add('vertica'), 'Add engine "vertica"';
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
    extension)
) {
    is $config->get(key => "engine.test.$key"), undef,
        qq{Engine "test" should have no $key set};
}

# Try all the properties.
my %props = (
    target     => 'db:firebird:foo',
    client     => 'poo',
    registry   => 'reg',
    top_dir    => 'top',
    plan_file  => 'my.plan',
    deploy_dir => 'dep',
    revert_dir => 'rev',
    verify_dir => 'ver',
    extension  => 'ddl',
);
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { %props },
}), $CLASS, 'Engine with all properties';
ok $cmd->add('firebird'), 'Add engine "firebird"';
$config->load;
while (my ($k, $v) = each %props) {
    is $config->get(key => "engine.firebird.$k"), $v,
        qq{Engine "firebird" should have $k set};
}

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

##############################################################################
# Test other set_* methods
for my $key (keys %props) {
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
    throws_ok { $cmd->$meth('nonexistent', 'shake' ) } 'App::Sqitch::X',
        'Should get error for nonexistent engine';
    is $@->ident, 'engine', 'Nonexistent engine error ident should be "engine"';
    is $@->message, __x(
        'Unknown engine "{engine}"',
        engine => 'nonexistent'
    ), 'Nonexistent engine error message should be correct';

    # Set one that exists.
    ok $cmd->$meth('pg', 'rock'), 'Set new $key';
    $config->load;
    is $config->get(key => "engine.pg.$key"), 'rock',
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
    ['  ', 'Target:           ', 'widgets'],
    ['  ', 'Registry:         ', 'sqitch'],
    ['  ', 'Client:           ', '/usr/sbin/sqlite3'],
    ['  ', 'Top Directory:    ', '.'],
    ['  ', 'Plan File:        ', 'foo.plan'],
    ['  ', 'Deploy Directory: ', 'deploy'],
    ['  ', 'Revert Directory: ', 'revert'],
    ['  ', 'Verify Directory: ', 'verify'],
    ['  ', 'Extension:        ', 'sql'],
], 'The full "sqlite" engine should have been shown';

# Try multiples.
ok $cmd->set_client(vertica => 'vsql.exe'), 'Set vertica client';
$config->load;
ok $cmd->show(qw(sqlite vertica firebird)), 'Show three engines';
is_deeply +MockOutput->get_emit, [
    ['* sqlite'],
    ['  ', 'Target:           ', 'widgets'],
    ['  ', 'Registry:         ', 'sqitch'],
    ['  ', 'Client:           ', '/usr/sbin/sqlite3'],
    ['  ', 'Top Directory:    ', '.'],
    ['  ', 'Plan File:        ', 'foo.plan'],
    ['  ', 'Deploy Directory: ', 'deploy'],
    ['  ', 'Revert Directory: ', 'revert'],
    ['  ', 'Verify Directory: ', 'verify'],
    ['  ', 'Extension:        ', 'sql'],
    ['* vertica'],
    ['  ', 'Target:           ', 'db:vertica:'],
    ['  ', 'Registry:         ', 'sqitch'],
    ['  ', 'Client:           ', 'vsql.exe'],
    ['  ', 'Top Directory:    ', '.'],
    ['  ', 'Plan File:        ', 'sqitch.plan'],
    ['  ', 'Deploy Directory: ', 'deploy'],
    ['  ', 'Revert Directory: ', 'revert'],
    ['  ', 'Verify Directory: ', 'verify'],
    ['  ', 'Extension:        ', 'sql'],
    ['* firebird'],
    ['  ', 'Target:           ', 'db:firebird:foo'],
    ['  ', 'Registry:         ', 'reg'],
    ['  ', 'Client:           ', 'poo'],
    ['  ', 'Top Directory:    ', 'top'],
    ['  ', 'Plan File:        ', 'my.plan'],
    ['  ', 'Deploy Directory: ', 'dep'],
    ['  ', 'Revert Directory: ', 'rev'],
    ['  ', 'Verify Directory: ', 'ver'],
    ['  ', 'Extension:        ', 'ddl'],
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
