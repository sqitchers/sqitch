#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 51;
use Test::More 'no_plan';
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

my $CLASS = 'App::Sqitch::Command::target';

##############################################################################
# Set up a test directory and config file.
my $tmp_dir = tempdir CLEANUP => 1;

File::Copy::syscopy file(qw(t target.conf))->stringify, "$tmp_dir"
    or die "Cannot copy t/target.conf to $tmp_dir: $!\n";
chdir $tmp_dir;
$ENV{SQITCH_CONFIG} = 'target.conf';

##############################################################################
# Load a target command and test the basics.
ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'target',
    config  => $config,
}), $CLASS, 'Target command';

can_ok $cmd, qw(
    options
    configure
    execute
    list
    add
    set_uri
    set_registry
    set_client
    remove
    rename
    rm
    show
);

is_deeply [$CLASS->options], [qw(
    registry|r=s
    client|c=s
    v|verbose+
)], 'Options should be correct';

# Check default attribute values.
is $cmd->verbose,  0,     'Default verbosity should be 0';
is $cmd->registry, undef, 'Default registry should be undef';
is $cmd->client,   undef, 'Default client should be undef';

# Make sure configure ignores config file.
is_deeply $CLASS->configure({ foo => 'bar'}, { hi => 'there' }),
    { hi => 'there' },
    'configure() should ignore config file';

##############################################################################
# Test list().
ok $cmd->list, 'Run list()';
is_deeply +MockOutput->get_emit, [['dev'], ['prod'], ['qa']],
    'The list of targets should have been output';

# Make it verbose.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, verbose => 1 }),
    $CLASS, 'Verbose target';
ok $cmd->list, 'Run verbose list()';
is_deeply +MockOutput->get_emit, [
    ["dev\tdb:pg:widgets"],
    ["prod\tdb:pg://prod.example.us/pr_widgets"],
    ["qa\tdb:pg://qa.example.com/qa_widgets"]
], 'The list of targets and their URIs should have been output';

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

    @args = ();
    throws_ok { $cmd->add('foo') } qr/USAGE/,
        'No URI arg to add() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should die on existing key.
throws_ok { $cmd->add('dev', 'db:pg:') } 'App::Sqitch::X',
    'Should get error for existing target';
is $@->ident, 'target', 'Existing target error ident should be "target"';
is $@->message, __x(
    'Target "{target}" already exists',
    target => 'dev'
), 'Existing target error message should be correct';

# Now add a new target.
ok $cmd->add('test', 'db:pg:test'), 'Add target "test"';
$config->load;
is $config->get(key => 'target.test.uri'), 'db:pg:test',
    'Target "test" URI should have been set';
is $config->get(key => 'target.test.registry'), undef,
    'Target "test" should have no registry set';
is $config->get(key => 'target.test.client'), undef,
    'Target "test" should have no client set';

# Try adding a target with a registry.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, registry => 'meta' }),
    $CLASS, 'Target with registry';
ok $cmd->add('withreg', 'db:pg:withreg'), 'Add target "withreg"';
$config->load;
is $config->get(key => 'target.withreg.uri'), 'db:pg:withreg',
    'Target "withreg" URI should have been set';
is $config->get(key => 'target.withreg.registry'), 'meta',
    'Target "withreg" registry should have been set';

# Try a client.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, client => 'hi.exe' }),
    $CLASS, 'Target with client';
ok $cmd->add('withcli', 'db:pg:withcli'), 'Add target "withcli"';
$config->load;
is $config->get(key => 'target.withcli.uri'), 'db:pg:withcli',
    'Target "withcli" URI should have been set';
is $config->get(key => 'target.withcli.registry'), undef,
    'Target "withcli" registry should not have been set';
is $config->get(key => 'target.withcli.client'), 'hi.exe',
    'Target "withcli" should have client set';

# Try both.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, client => 'ack', registry => 'foo' }),
    $CLASS, 'Target with client and registry';
ok $cmd->add('withboth', 'db:pg:withboth'), 'Add target "withboth"';
$config->load;
is $config->get(key => 'target.withboth.uri'), 'db:pg:withboth',
    'Target "withboth" URI should have been set';
is $config->get(key => 'target.withboth.registry'), 'foo',
    'Target "withboth" registry should not been set';
is $config->get(key => 'target.withboth.client'), 'ack',
    'Target "withboth" should have client set';

##############################################################################
# Test set_uri().
MISSINGARGS: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->set_uri } qr/USAGE/,
        'No name arg to set_uri() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';

    @args = ();
    throws_ok { $cmd->set_uri('foo') } qr/USAGE/,
        'No URI arg to set_uri() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should get an error if the target does not exist.
throws_ok { $cmd->set_uri('nonexistent', 'db:pg:' ) } 'App::Sqitch::X',
    'Should get error for nonexistent target';
is $@->ident, 'target', 'Nonexistent target error ident should be "target"';
is $@->message, __x(
    'No such target "{target}"',
    target => 'nonexistent'
), 'Nonexistent target error message should be correct';

# Set one that exists.
ok $cmd->set_uri('withboth', 'db:pg:newuri'), 'Set new URI';
$config->load;
is $config->get(key => 'target.withboth.uri'), 'db:pg:newuri',
    'Target "withboth" should have new URI';

# Make sure the URI is a database URI.
ok $cmd->set_uri('withboth', 'postgres:stuff'), 'Set new URI';
$config->load;
is $config->get(key => 'target.withboth.uri'), 'db:postgres:stuff',
    'Target "withboth" should have new DB URI';

##############################################################################
# Test set_registry() and set_client.
for my $key (qw(registry client)) {
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

    # Should get an error if the target does not exist.
    throws_ok { $cmd->$meth('nonexistent', 'shake' ) } 'App::Sqitch::X',
        'Should get error for nonexistent target';
    is $@->ident, 'target', 'Nonexistent target error ident should be "target"';
    is $@->message, __x(
        'No such target "{target}"',
        target => 'nonexistent'
    ), 'Nonexistent target error message should be correct';

    # Set one that exists.
    ok $cmd->$meth('withboth', 'rock'), 'Set new $key';
    $config->load;
    is $config->get(key => "target.withboth.$key"), 'rock',
        qq{Target "withboth" should have new $key};
}

##############################################################################
# Test execute().
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch }), $CLASS, 'Simple target';
for my $spec (
    [ undef,          'list'   ],
    [ 'list'                   ],
    [ 'add'                    ],
    [ 'set-uri'                ],
    [ 'set-url',     'set_uri' ],
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
    ok $cmd->execute($spec->[0], qw(foo bar)),
        "Execute " . ($spec->[0] // 'undef') . ' with args';
    is_deeply \@args, [$cmd, qw(foo bar)],
        "$meth() should have been passed args";
}

# Make sure an invalid action dies.
throws_ok { $cmd->execute('nonexistent') } 'App::Sqitch::X',
    'Should get an exception for a nonexistent action';
is $@->ident, 'target', 'Nonexistent action error ident should be "target"';
is $@->message, __x(
    'Unknown action "{action}"',
    action => 'nonexistent',
), 'Nonexistent action error message should be correct';
