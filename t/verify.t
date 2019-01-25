#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use Test::Warn;
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::verify';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    from_change
    to_change
    variables
    does
);

ok $CLASS->does("App::Sqitch::Role::$_"), "$CLASS does $_"
    for qw(ContextCommand ConnectingCommand);

is_deeply [$CLASS->options], [qw(
    target|t=s
    from-change|from=s
    to-change|to=s
    set|s=s%
    plan-file|f=s
    top-dir=s
    registry=s
    client|db-client=s
    db-name|d=s
    db-user|db-username|u=s
    db-host|h=s
    db-port|p=i
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';

my $config = TestConfig->new(
    'core.engine'    => 'sqlite',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);
my $sqitch = App::Sqitch->new(config => $config);

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {
    _params => [],
    _cx     => [],
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    from_change => 'foo',
    to_change   => 'bar',
    set  => { foo => 'bar' },
}), {
    from_change => 'foo',
    to_change   => 'bar',
    variables   => { foo => 'bar' },
    _params     => [],
    _cx         => [],
}, 'Should have changes and variables from options';

CONFIG: {
    my $config = TestConfig->new(
        'verify.variables' => { foo => 'bar', hi => 21 },
    );
    is_deeply $CLASS->configure($config, {}), { _params => [], _cx => [] },
        'Should have no config if no options';
}

##############################################################################
# Test construction.
isa_ok my $verify = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new status with target';
is $verify->target, 'foo', 'Should have target "foo"';

isa_ok $verify = $CLASS->new(sqitch => $sqitch), $CLASS;
is $verify->target, undef, 'Default target should be undef';
is $verify->from_change, undef, 'from_change should be undef';
is $verify->to_change, undef, 'to_change should be undef';

##############################################################################
# Test _collect_vars.
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $verify->_collect_vars($target) }, {}, 'Should collect no variables';

# Add core variables.
$config->update('core.variables' => { prefix => 'widget', priv => 'SELECT' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core vars';

# Add deploy variables.
$config->update('deploy.variables' => { dance => 'salsa', priv => 'UPDATE' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars';

# Add verify variables.
$config->update('verify.variables' => { dance => 'disco', lunch => 'pizza' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'pizza',
}, 'Should override deploy vars with verify vars';

# Add engine variables.
$config->update('engine.pg.variables' => { lunch => 'burrito', drink => 'whiskey' });
my $uri = URI::db->new('db:pg:');
$target = App::Sqitch::Target->new(sqitch => $sqitch, uri => $uri);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override verify vars with engine vars';

# Add target variables.
$config->update('target.foo.variables' => { drink => 'scotch', status => 'winning' });
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override engine vars with target vars';

# Add --set variables.
$verify = $CLASS->new(
    sqitch => $sqitch,
    variables => { status => 'tired', herb => 'oregano' },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $verify->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should override target vars with --set variables';

$config->replace(
    'core.engine'    => 'sqlite',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);
$verify = $CLASS->new( sqitch => $sqitch, no_prompt => 1);

##############################################################################
# Test execution.
# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(verify => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $verify->execute, 'Execute with nothing.';
is_deeply \@args, [undef, undef],
    'Two undefs should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

ok $verify->execute('@alpha'), 'Execute from "@alpha"';
is_deeply \@args, ['@alpha', undef],
    '"@alpha" and undef should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should again have no warnings';

ok $verify->execute('@alpha', '@beta'), 'Execute from "@alpha" to "@beta"';
is_deeply \@args, ['@alpha', '@beta'],
    '"@alpha" and "@beat" should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should still have no warnings';

isa_ok $verify = $CLASS->new(
    sqitch      => $sqitch,
    from_change => 'foo',
    to_change   => 'bar',
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with from, to, and variables';

ok $verify->execute, 'Execute again';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Still should have no warnings';

# Pass and specify changes.
ok $verify->execute('roles', 'widgets'), 'Execute with command-line args';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many changes specified; verifying from "{from}" to "{to}"',
    from => 'foo',
    to   => 'bar',
)]], 'Should have warning about which roles are used';

# Pass a target.
$target = 'db:pg:';
my $mock_cmd = Test::MockModule->new(ref $verify);
my ($target_name_arg, $orig_meth);
$mock_cmd->mock(parse_args => sub {
    my $self = shift;
    my %p = @_;
    my @ret = $self->$orig_meth(@_);
    $target_name_arg = $ret[0][0]->name;
    $ret[0][0] = $self->default_target;
    return @ret;
});
$orig_meth = $mock_cmd->original('parse_args');

ok $verify->execute($target), 'Execute with target arg';
is $target_name_arg, $target, 'The target should have been passed to the engine';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should once again have no warnings';

# Pass a --target option.
isa_ok $verify = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS, 'Object with target';
$target_name_arg = undef;
@vars = ();
ok $verify->execute, 'Execute with no args';
is $target_name_arg, $target, 'The target option should have been passed to the engine';
is_deeply \@args, [undef, undef], 'Undefs should be passed to the engine';
is_deeply {@vars}, {}, 'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should once again have no warnings';

# Pass a target, get a warning.
ok $verify->execute('db:sqlite:', 'roles', 'widgets'),
    'Execute with two targegs and two changes';
is $target_name_arg, $target, 'The target option should have been passed to the engine';
is_deeply \@args, ['roles', 'widgets'],
    'The two changes should be passed to the engine';
is_deeply {@vars}, {}, 'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => $verify->default_target->name,
)]], 'Should have warning about too many targets';

# Make sure we get an exception for unknown args.
throws_ok { $verify->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'verify', 'Unknow arg ident should be "verify"';
is $@->message, __x(
    'Unknown argument "{arg}"',
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $verify->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'verify', 'Unknow args ident should be "verify"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

done_testing;
