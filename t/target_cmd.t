#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 351;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Test::Warn;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::NoWarnings;
use File::Copy;
use Path::Class;
use File::Temp 'tempdir';
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::target';

##############################################################################
# Set up a test directory and config file.
my $tmp_dir = tempdir CLEANUP => 1;

File::Copy::copy file(qw(t target.conf))->stringify, "$tmp_dir"
    or die "Cannot copy t/target.conf to $tmp_dir: $!\n";
File::Copy::copy file(qw(t engine sqitch.plan))->stringify, "$tmp_dir"
    or die "Cannot copy t/engine/sqitch.plan to $tmp_dir: $!\n";
chdir $tmp_dir;
my $psql = 'psql' . (App::Sqitch::ISWIN ? '.exe' : '');

##############################################################################
# Load a target command and test the basics.
my $config = TestConfig->from(local => 'target.conf');
ok my $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'target',
    config  => $config,
}), $CLASS, 'Target command';
isa_ok $cmd, 'App::Sqitch::Command', 'Target command';

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
    does
);

ok $CLASS->does("App::Sqitch::Role::TargetConfigCommand"),
    "$CLASS does TargetConfigCommand";

is_deeply [$CLASS->options], [qw(
    uri=s
    plan-file|f=s
    registry=s
    client=s
    extension=s
    top-dir=s
    dir|d=s%
    set|s=s%
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';

##############################################################################
# Test configure().
is_deeply $cmd->properties, {}, 'Default properties should be empty';

# Make sure configure ignores config file.
is_deeply $CLASS->configure({ foo => 'bar'}, {}), { properties => {} },
    'configure() should ignore config file';

# Check default property values.
ok my $conf = $CLASS->configure($config, {
    top_dir             => 'top',
    plan_file           => 'my.plan',
    registry            => 'bats',
    client              => 'cli',
    extension           => 'ddl',
    uri                 => 'db:pg:foo',
    dir => {
        deploy          => 'dep',
        revert          => 'rev',
        verify          => 'ver',
        reworked        => 'wrk',
        reworked_deploy => 'rdep',
        reworked_revert => 'rrev',
        reworked_verify => 'rver',
    },
    set => {
        foo => 'bar',
        prefix => 'x_',
    },
}), 'Get full config';

is_deeply $conf->{properties}, {
    top_dir             => 'top',
    plan_file           => 'my.plan',
    registry            => 'bats',
    client              => 'cli',
    extension           => 'ddl',
    uri                 => URI->new('db:pg:foo'),
    deploy_dir          => 'dep',
    revert_dir          => 'rev',
    verify_dir          => 'ver',
    reworked_dir        => 'wrk',
    reworked_deploy_dir => 'rdep',
    reworked_revert_dir => 'rrev',
    reworked_verify_dir => 'rver',
    variables => {
        foo => 'bar',
        prefix => 'x_',
    }
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
is $@->ident, 'target', 'Invalid directory ident should be "target"';
is $@->message, __x(
    'Unknown directory name: {prop}',
    prop => 'foo',
), 'The invalid directory messsage should be correct';

throws_ok { $CLASS->new($CLASS->configure({}, {
    dir => { foo => 'bar', cavort => 'ha' },
})) } 'App::Sqitch::X',  'Should fail on invalid directory names';
is $@->ident, 'target', 'Invalid directories ident should be "target"';
is $@->message, __x(
    'Unknown directory names: {props}',
    props => 'cavort, foo',
), 'The invalid properties messsage should be correct';

##############################################################################
# Test list().
ok $cmd->list, 'Run list()';
is_deeply +MockOutput->get_emit, [['dev'], ['prod'], ['qa']],
    'The list of targets should have been output';

# Make it verbose.
isa_ok $cmd = $CLASS->new({
    sqitch => App::Sqitch->new( config => $config, options => { verbosity => 1 })
}), $CLASS, 'Verbose engine';
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
dir_not_exists_ok $_ for qw(deploy revert verify);
ok $cmd->add('test', 'db:pg:test'), 'Add target "test"';
dir_exists_ok $_ for qw(deploy revert verify);
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
    extension
)) {
    is $config->get(key => "target.test.$key"), undef,
        qq{Target "test" should have no $key set};
}
is_deeply $config->get_section(section => 'target.test.variables'), {},
    qq{Target "test" should have no variables set}
;
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
    extension
)) {
    is $config->get(key => "target.withreg.$key"), undef,
        qq{Target "test" should have no $key set};

}
is_deeply $config->get_section(section => 'target.withreg.variables'), {},
    qq{Target "withreg" should have no variables set};

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
    extension
)) {
    is $config->get(key => "target.withcli.$key"), undef,
        qq{Target "withcli" should have no $key set};
}
is_deeply $config->get_section(section => 'target.withcli.variables'), {},
        qq{Target "withcli" should have no variables set};

# Try both.
isa_ok $cmd = $CLASS->new({
    sqitch => $sqitch,
    properties => { client => 'ack', registry => 'foo', variables => { a => 'y' } },
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
    extension
)) {
    is $config->get(key => "target.withboth.$key"), undef,
        qq{Target "withboth" should have no $key set};
}
is_deeply $config->get_section(section => 'target.withboth.variables'), {a => 'y'},
        qq{Target "withboth" should have variables set};

# Try all the properties.
my %props = (
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
    variables           => { ay => 'first', Bee => 'second' },
);
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { %props },
}), $CLASS, 'Target with all properties';
file_not_exists_ok 'my.plan';
dir_not_exists_ok dir $_ for qw(top/deploy top/revert top/verify r/d r/revert r/verify);
ok $cmd->add('withall', 'db:pg:withall'), 'Add target "withall"';
dir_exists_ok dir $_ for qw(top/deploy top/revert top/verify r/d r/revert r/verify);
file_exists_ok 'my.plan';
$config->load;
is $config->get(key => "target.withall.uri"), 'db:pg:withall',
        qq{Target "withall" should have uri set};
while (my ($k, $v) = each %props) {
    if ($k ne 'variables') {
        is $config->get(key => "target.withall.$k"), $v,
            qq{Target "withall" should have $k set};
    } else {
        is_deeply $config->get_section(section => "target.withall.$k"), $v,
            qq{Target "withall" should have $k set};
    }
}

##############################################################################
# Test alter().
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
}), $CLASS, 'Target with no properties';

MISSINGARGS: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->alter } qr/USAGE/,
        'No name arg to alter() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';
}

# Should die on missing key.
throws_ok { $cmd->alter('nonesuch') } 'App::Sqitch::X',
    'Should get error for missing target';
is $@->ident, 'target', 'Missing target error ident should be "target"';
is $@->message, __x(
    'Missing Target "{target}"; use "{command}" to add it',
    target  => 'nonesuch',
    command => 'add nonesuch $uri',
), 'Missing target error message should be correct';

# Should include the URI, if present, in the error message.
$cmd->properties->{uri} = URI::db->new('db:pg:');
throws_ok { $cmd->alter('nonesuch') } 'App::Sqitch::X',
    'Should get error for missing target with URI';
is $@->ident, 'target', 'Missing target with URI error ident should be "target"';
is $@->message, __x(
    'Missing Target "{target}"; use "{command}" to add it',
    target  => 'nonesuch',
    command => 'add nonesuch db:pg:',
), 'Missing target error message should include URI';


# Try all the properties.
%props = (
    uri                 => URI->new('db:firebird:bar'),
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
    variables           => { ay => 'x', ceee => 'third' },
);
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { %props },
}), $CLASS, 'Target with more properties';
ok $cmd->alter('withall'), 'Alter target "withall"';
$config->load;
while (my ($k, $v) = each %props) {
    if ($k ne 'variables') {
        is $config->get(key => "target.withall.$k"), $v,
            qq{Target "withall" should have $k set};
    } else {
        $v->{Bee} = 'second';
        is_deeply $config->get_section(section => "target.withall.$k"), $v,
            qq{Target "withall" should have merged $k set};
    }
}

# Try changing the top directory.
isa_ok $cmd = $CLASS->new({
    sqitch     => $sqitch,
    properties => { top_dir => dir 'big' },
}), $CLASS, 'Target with new top_dir property';
dir_not_exists_ok dir $_ for qw(big big/deploy big/revert big/verify);
ok $cmd->alter('withall'), 'Alter target "withall"';
dir_exists_ok dir $_ for qw(big big/deploy big/revert big/verify);
$config->load;
is $config->get(key => 'target.withall.top_dir'), 'big',
    'The withall top_dir should have been set';

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
    next if $key =~ /^(?:reworked|variables)/;
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
    my $exp = $key eq 'uri' ? 'db:rock' : 'rock';
    is $config->get(key => "target.withboth.$key"), $exp,
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
ok $config->get(key => "target.àlafois.uri"),
    qq{Target "àlafois" should now be present};
is $config->get(key => "target.àlafois.variables.a"), 'y',
    qq{Target "àlafois" variables should now be present};
is $config->get(key => "target.withboth.uri"), undef,
    qq{Target "withboth" should no longer be present};
is $config->get(key => "target.withboth.variables.a"), undef,
    qq{Target "withboth" variables should be gone};
is_deeply $config->get_section(section => "target.àlafois.variables"), { a => 'y' },
    qq{Target "àlafois" should have variables};

# Make sure we die on dependencies.
$config->group_set( $config->local_file, [
    {key => 'core.target', value => 'prod'},
    {key => 'engine.firebird.target', value => 'prod'},
]);
$cmd->sqitch->config->load;
# Should get an error for a target with dependencies.
throws_ok { $cmd->rename('prod', 'fodder' ) } 'App::Sqitch::X',
    'Should get error renaming a target with dependencies';
is $@->ident, 'target', 'Dependency target error ident should be "target"';
is $@->message, __x(
    q{Cannot rename target "{target}" because it's referenced by: {engines}},
    target => 'prod',
    engines => 'core.target, engine.firebird.target',
), 'Dependency target error message should be correct';

# Should get no error removing a target with no variables.
ok $cmd->rename('test', 'funky'), 'Rename "test"';
$config->load;
ok $config->get(key => "target.funky.uri"),
    qq{Target "funky" should now be present};
is $config->get(key => "target.test.uri"), undef,
    qq{Target "test" should no longer be present};
is_deeply $config->get_section(section => "target.funky.variables"), {},
    qq{Target "funcky" should have no variables};

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
is_deeply $config->get_section(section => "target.àlafois.variables"), {},
    qq{Target "àlafois" variables should be gone, too};

throws_ok { $cmd->remove('prod' ) } 'App::Sqitch::X',
    'Should get error removing a target with dependencies';
is $@->ident, 'target', 'Dependency target error ident should be "target"';
is $@->message, __x(
    q{Cannot rename target "{target}" because it's referenced by: {engines}},
    target => 'prod',
    engines => 'core.target, engine.firebird.target',
), 'Dependency target error message should be correct';

# Remove one without variables, too.
ok $cmd->remove('funky'), 'Remove "funky"';
$config->load;
is $config->get(key => "target.funky.uri"), undef,
    qq{Target "funky" should now be gone};

##############################################################################
# Test show.
ok $cmd->show, 'Run show()';
is_deeply +MockOutput->get_emit, [
    ['dev'], ['prod'], ['qa'], ['withall'], ['withcli'], ['withreg']
], 'Show with no names should emit the list of targets';

# Try one target.
ok $cmd->show('dev'), 'Show dev';
is_deeply +MockOutput->get_emit, [
    ['* dev'],
    ['    ', 'URI:           ', 'db:pg:widgets'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', $psql],
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
    ['    ', 'No Variables'],
], 'The "dev" target should have been shown';

# Try a target with a non-default client.
ok $cmd->show('withcli'), 'Show withcli';
is_deeply +MockOutput->get_emit, [
    ['* withcli'],
    ['    ', 'URI:           ', 'db:pg:withcli'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', 'hi.exe'],
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
    ['    ', 'No Variables'],
], 'The "with_cli" target should have been shown';

# Try a target with a non-default registry.
ok $cmd->show('withreg'), 'Show withreg';
is_deeply +MockOutput->get_emit, [
    ['* withreg'],
    ['    ', 'URI:           ', 'db:pg:withreg'],
    ['    ', 'Registry:      ', 'meta'],
    ['    ', 'Client:        ', $psql],
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
    ['    ', 'No Variables'],
], 'The "withreg" target should have been shown';

# Try a target with variables.
ok $cmd->show('withall'), 'Show withall';
#use Data::Dump; ddx +MockOutput->get_emit;
is_deeply +MockOutput->get_emit, [
    ['* withall'],
    ['    ', 'URI:           ', 'db:firebird:bar'],
    ['    ', 'Registry:      ', 'migrations'],
    ['    ', 'Client:        ', 'argh'],
    ['    ', 'Top Directory: ', 'big'],
    ['    ', 'Plan File:     ', 'fb.plan'],
    ['    ', 'Extension:     ', 'fbsql'],
    ['    ', 'Script Directories:'],
    ['    ', '  Deploy:      ', dir qw(fb dep)],
    ['    ', '  Revert:      ', dir qw(fb rev)],
    ['    ', '  Verify:      ', dir qw(fb ver)],
    ['    ', 'Reworked Script Directories:'],
    ['    ', '  Reworked:    ', dir qw(fb r)],
    ['    ', '  Deploy:      ', dir qw(fb r d)],
    ['    ', '  Revert:      ', dir qw(fb r revert)],
    ['    ', '  Verify:      ', dir qw(fb r verify)],
    ['    ', 'Variables:'],
    ['  ay:   x'],
    ['  Bee:  second'],
    ['  ceee: third'],
], 'The "withall" target should have been shown with variables';

# Try multiples.
ok $cmd->show(qw(dev qa withreg)), 'Show three targets';
is_deeply +MockOutput->get_emit, [
    ['* dev'],
    ['    ', 'URI:           ', 'db:pg:widgets'],
    ['    ', 'Registry:      ', 'sqitch'],
    ['    ', 'Client:        ', $psql],
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
    ['    ', 'No Variables'],
    ['* qa'],
    ['    ', 'URI:           ', 'db:pg://qa.example.com/qa_widgets'],
    ['    ', 'Registry:      ', 'meta'],
    ['    ', 'Client:        ', '/usr/sbin/psql'],
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
    ['    ', 'No Variables'],
    ['* withreg'],
    ['    ', 'URI:           ', 'db:pg:withreg'],
    ['    ', 'Registry:      ', 'meta'],
    ['    ', 'Client:        ', $psql],
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
    ['    ', 'No Variables'],
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

##############################################################################
# Test URI validation.
for my $val (
    'rock',
    'https://www.google.com/',
) {
    my $uri = URI->new($val);
    throws_ok {
        $CLASS->new({ sqitch => $sqitch, properties => { uri => $uri } })
    } 'App::Sqitch::X', "Invalid URI $val should throw an error";
    is $@->ident, 'target', qq{Invalid URI $val error ident should be "target"};
    is $@->message, __x(
        'URI "{uri}" is not a database URI',
        uri => $uri,
    ), qq{Invalid URI $val error message should be correct};
}

my $uri = URI->new('db:');
throws_ok {
    $CLASS->new({ sqitch => $sqitch, properties => { uri => $uri } })
} 'App::Sqitch::X', 'Engineless URI should throw an error';
is $@->ident, 'target', 'Engineless URI error ident should be "target"';
is $@->message, __x(
    'No database engine in URI "{uri}"',
    uri => $uri,
), 'Engineless URI error message should be correct';

$uri = URI->new('db:nonesuch:foo');
throws_ok {
    $CLASS->new({ sqitch => $sqitch, properties => { uri => $uri } })
} 'App::Sqitch::X', 'Unknown engine URI should throw an error';
is $@->ident, 'target', 'Unknown engine URI error ident should be "target"';
is $@->message, __x(
    'Unknown engine "{engine}" in URI "{uri}"',
    uri    => $uri,
    engine => 'nonesuch',
), 'Unknown engine URI error message should be correct';
