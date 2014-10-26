#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 230;
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

my $CLASS = 'App::Sqitch::Command::target';

##############################################################################
# Set up a test directory and config file.
my $tmp_dir = tempdir CLEANUP => 1;

File::Copy::copy file(qw(t target.conf))->stringify, "$tmp_dir"
    or die "Cannot copy t/target.conf to $tmp_dir: $!\n";
chdir $tmp_dir;
$ENV{SQITCH_CONFIG} = 'target.conf';
my $psql = 'psql' . ($^O eq 'MSWin32' ? '.exe' : '');

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
    set|s=s%
    registry|r=s
    client|c=s
    verbose|v+
)], 'Options should be correct';

# Check default property values.
is $cmd->verbose,  0,     'Default verbosity should be 0';
is_deeply $cmd->properties, {}, 'Default properties should be empty';

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
    is $config->get(key => "target.test.$key"), undef,
        qq{Target "test" should have no $key set};
}

# Try adding a target with a registry.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { registry => 'meta' },
}), $CLASS, 'Target with registry';
ok $cmd->add('withreg', 'db:pg:withreg'), 'Add target "withreg"';
$config->load;
is $config->get(key => 'target.withreg.uri'), 'db:pg:withreg',
    'Target "withreg" URI should have been set';
is $config->get(key => 'target.withreg.registry'), 'meta',
    'Target "withreg" registry should have been set';
for my $key (qw(
    client
    top_dir
    plan_file
    deploy_dir
    revert_dir
    verify_dir
    extension)
) {
    is $config->get(key => "target.withreg.$key"), undef,
        qq{Target "test" should have no $key set};
}

# Try a client.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { client => 'hi.exe' },
}), $CLASS, 'Target with client';
ok $cmd->add('withcli', 'db:pg:withcli'), 'Add target "withcli"';
$config->load;
is $config->get(key => 'target.withcli.uri'), 'db:pg:withcli',
    'Target "withcli" URI should have been set';
is $config->get(key => 'target.withcli.client'), 'hi.exe',
    'Target "withcli" should have client set';
for my $key (qw(
    registry
    top_dir
    plan_file
    deploy_dir
    revert_dir
    verify_dir
    extension)
) {
    is $config->get(key => "target.withcli.$key"), undef,
        qq{Target "withcli" should have no $key set};
}

# Try both.
isa_ok $cmd = $CLASS->new({
    sqitch => $sqitch,
    properties => { client => 'ack', registry => 'foo' },
}), $CLASS, 'Target with client and registry';
ok $cmd->add('withboth', 'db:pg:withboth'), 'Add target "withboth"';
$config->load;
is $config->get(key => 'target.withboth.uri'), 'db:pg:withboth',
    'Target "withboth" URI should have been set';
is $config->get(key => 'target.withboth.registry'), 'foo',
    'Target "withboth" registry should have been set';
is $config->get(key => 'target.withboth.client'), 'ack',
    'Target "withboth" should have client set';
for my $key (qw(
    top_dir
    plan_file
    deploy_dir
    revert_dir
    verify_dir
    extension)
) {
    is $config->get(key => "target.withboth.$key"), undef,
        qq{Target "withboth" should have no $key set};
}

# Try all the properties.
my %props = (
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
}), $CLASS, 'Target with all properties';
ok $cmd->add('withall', 'db:pg:withall'), 'Add target "withall"';
$config->load;
while (my ($k, $v) = each %props) {
    is $config->get(key => "target.withall.$k"), $v,
        qq{Target "withall" should have $k set};
}

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
    'Unknown target "{target}"',
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

    # Should get an error if the target does not exist.
    throws_ok { $cmd->$meth('nonexistent', 'shake' ) } 'App::Sqitch::X',
        'Should get error for nonexistent target';
    is $@->ident, 'target', 'Nonexistent target error ident should be "target"';
    is $@->message, __x(
        'Unknown target "{target}"',
        target => 'nonexistent'
    ), 'Nonexistent target error message should be correct';

    # Set one that exists.
    ok $cmd->$meth('withboth', 'rock'), 'Set new $key';
    $config->load;
    is $config->get(key => "target.withboth.$key"), 'rock',
        qq{Target "withboth" should have new $key};
}

##############################################################################
# Test rename.
MISSINGARGS: {
    # Test handling of no names.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->rename } qr/USAGE/,
        'No name args to rename() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';

    @args = ();
    throws_ok { $cmd->rename('foo') } qr/USAGE/,
        'No second arg to rename() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should get an error if the target does not exist.
throws_ok { $cmd->rename('nonexistent', 'existant' ) } 'App::Sqitch::X',
    'Should get error for nonexistent target';
is $@->ident, 'target', 'Nonexistent target error ident should be "target"';
is $@->message, __x(
    'Unknown target "{target}"',
    target => 'nonexistent'
), 'Nonexistent target error message should be correct';

# Rename one that exists.
ok $cmd->rename('withboth', 'àlafois'), 'Rename';
$config->load;
is $config->get(key => "target.àlafois.uri"), 'db:postgres:stuff',
    qq{Target "àlafois" should now be present};
is $config->get(key => "target.withboth.uri"), undef,
    qq{Target "withboth" should no longer be present};

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

# Should get an error if the target does not exist.
throws_ok { $cmd->remove('nonexistent', 'existant' ) } 'App::Sqitch::X',
    'Should get error for nonexistent target';
is $@->ident, 'target', 'Nonexistent target error ident should be "target"';
is $@->message, __x(
    'Unknown target "{target}"',
    target => 'nonexistent'
), 'Nonexistent target error message should be correct';

# Remove one that exists.
ok $cmd->remove('àlafois'), 'Remove';
$config->load;
is $config->get(key => "target.àlafois.uri"), undef,
    qq{Target "àlafois" should now be gone};

##############################################################################
# Test show.
ok $cmd->show, 'Run show()';
is_deeply +MockOutput->get_emit, [
    ['dev'], ['prod'], ['qa'], ['test'], ['withall'], ['withcli'], ['withreg']
], 'Show with no names should emit the list of targets';

# Try one target.
ok $cmd->show('dev'), 'Show dev';
is_deeply +MockOutput->get_emit, [
    ['* dev'],
    ['  ', 'URI:      ', 'db:pg:widgets'],
    ['  ', 'Registry: ', 'sqitch'],
    ['  ', 'Client:   ', $psql],
], 'The "dev" target should have been shown';

# Try a target with a non-default client.
ok $cmd->show('withcli'), 'Show withcli';
is_deeply +MockOutput->get_emit, [
    ['* withcli'],
    ['  ', 'URI:      ', 'db:pg:withcli'],
    ['  ', 'Registry: ', 'sqitch'],
    ['  ', 'Client:   ', 'hi.exe'],
], 'The "with_cli" target should have been shown';

# Try a target with a non-default registry.
ok $cmd->show('withreg'), 'Show withreg';
is_deeply +MockOutput->get_emit, [
    ['* withreg'],
    ['  ', 'URI:      ', 'db:pg:withreg'],
    ['  ', 'Registry: ', 'meta'],
    ['  ', 'Client:   ', $psql],
], 'The "with_reg" target should have been shown';

# Try multiples.
ok $cmd->show(qw(dev qa withreg)), 'Show three targets';
is_deeply +MockOutput->get_emit, [
    ['* dev'],
    ['  ', 'URI:      ', 'db:pg:widgets'],
    ['  ', 'Registry: ', 'sqitch'],
    ['  ', 'Client:   ', $psql],
    ['* qa'],
    ['  ', 'URI:      ', 'db:pg://qa.example.com/qa_widgets'],
    ['  ', 'Registry: ', 'meta'],
    ['  ', 'Client:   ', '/usr/sbin/psql'],
    ['* withreg'],
    ['  ', 'URI:      ', 'db:pg:withreg'],
    ['  ', 'Registry: ', 'meta'],
    ['  ', 'Client:   ', $psql],
], 'All three targets should have been shown';

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
