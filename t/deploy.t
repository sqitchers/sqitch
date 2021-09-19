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

my $CLASS = 'App::Sqitch::Command::deploy';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    to_change
    mode
    log_only
    lock_timeout
    execute
    variables
    does
    _collect_vars
);

ok $CLASS->does("App::Sqitch::Role::$_"), "$CLASS does $_"
    for qw(ContextCommand ConnectingCommand);

is_deeply [$CLASS->options], [qw(
    target|t=s
    to-change|to|change=s
    mode=s
    set|s=s%
    log-only
    lock-timeout=i
    verify!
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
    mode     => 'all',
    verify   => 0,
    log_only => 0,
    _params  => [],
    _cx      => [],
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    mode         => 'tag',
    verify       => 1,
    log_only     => 1,
    lock_timeout => 30,
    set          => { foo => 'bar' },
    _params      => [],
    _cx          => [],
}), {
    mode         => 'tag',
    verify       => 1,
    log_only     => 1,
    lock_timeout => 30,
    variables    => { foo => 'bar' },
    _params      => [],
    _cx          => [],
}, 'Should have mode, verify, set, log-only, & loock-timeout options';

CONFIG: {
    my $config = TestConfig->new(
        'deploy.mode'      => 'change',
        'deploy.verify'    => 1,
        'deploy.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {
        mode     => 'change',
        verify   => 1,
        log_only => 0,
        _params  => [],
        _cx      => [],
    }, 'Should have mode and verify configuration';
}

##############################################################################
# Test construction.
isa_ok my $deploy = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new deploy with target';
is $deploy->target, 'foo', 'Should have target "foo"';

isa_ok $deploy = $CLASS->new(sqitch => $sqitch), $CLASS;
is $deploy->target, undef, 'Should have undef default target';
is $deploy->to_change, undef, 'to_change should be undef';
is $deploy->mode, 'all', 'mode should be "all"';

##############################################################################
# Test _collect_vars.
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $deploy->_collect_vars($target) }, {}, 'Should collect no variables';

# Add core variables.
$config->update('core.variables' => { prefix => 'widget', priv => 'SELECT' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $deploy->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core vars';

# Add deploy variables.
$config->update('deploy.variables' => { dance => 'salsa', priv => 'UPDATE' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $deploy->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars';

# Add engine variables.
$config->update('engine.pg.variables' => { dance => 'disco', lunch => 'pizza' });
my $uri = URI::db->new('db:pg:');
$target = App::Sqitch::Target->new(sqitch => $sqitch, uri => $uri);
is_deeply { $deploy->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'pizza',
}, 'Should override deploy vars with engine vars';

# Add target variables.
$config->update('target.foo.variables' => { lunch => 'burrito', drink => 'whiskey' });
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $deploy->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override engine vars with target vars';

# Add --set variables.
$deploy = $CLASS->new(
    sqitch => $sqitch,
    variables => { drink => 'scotch', status => 'winning' },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $deploy->_collect_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override target vars with --set variables';

##############################################################################
# Test execution.
# Mock parse_args() so that we can grab the target it returns.
my $mock_cmd = Test::MockModule->new($CLASS);
my $parser;
$mock_cmd->mock(parse_args => sub {
    my @ret = $parser->(@_);
    $target = $ret[0][0];
    return @ret;
});
$parser = $mock_cmd->original('parse_args');

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine');
my @args;
$mock_engine->mock(deploy => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $deploy->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@args, ['@alpha', 'all'],
    '"@alpha" "all", and 0 should be passed to the engine';
ok $target, 'Should have a target';
ok !$target->engine->log_only, 'The engine should not be set log_only';
is $target->engine->lock_timeout, App::Sqitch::Engine::default_lock_timeout(),
    'The engine should have the default lock_timeout';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

@args = ();
ok $deploy->execute, 'Execute';
is_deeply \@args, [undef, 'all'],
    'undef and "all" should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Try passing the change.
ok $deploy->execute('widgets'), 'Execute with change';
is_deeply \@args, ['widgets', 'all'],
    '"widgets" and "all" should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Try passing the target.
ok $deploy->execute('db:pg:foo'), 'Execute with target';
is_deeply \@args, [undef, 'all'],
    'undef and "all" should be passed to the engine';
is $target->name, 'db:pg:foo', 'The target should be as specified';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass both!
ok $deploy->execute('db:pg:blah', 'widgets'), 'Execute with change and target';
is_deeply \@args, ['widgets', 'all'],
    '"widgets" and "all" should be passed to the engine';
is $target->name, 'db:pg:blah', 'The target should be as specified';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Reverse them!
ok $deploy->execute('db:pg:blah', 'widgets'), 'Execute with target and change';
is_deeply \@args, ['widgets', 'all'],
    '"widgets" and "all" should be passed to the engine';
is $target->name, 'db:pg:blah', 'The target should be as specified';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Now pass a bunch of options.
$config->replace(
    'core.engine'    => 'sqlite',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);
isa_ok $deploy = $CLASS->new(
    sqitch       => $sqitch,
    to_change    => 'foo',
    target       => 'db:pg:hi',
    mode         => 'tag',
    log_only     => 1,
    lock_timeout => 30,
    verify       => 1,
    variables    => { foo => 'bar', one => 1 },
), $CLASS, 'Object with to, mode, log_only, and variables';

@args = ();
ok $deploy->execute, 'Execute again';
ok $target->engine->with_verify, 'Engine should verify';
ok $target->engine->log_only, 'The engine should be set log_only';
is $target->engine->lock_timeout, 30, 'The lock timeout should be set to 30';
is_deeply \@args, ['foo', 'tag'],
    '"foo", "tag", and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is $target->name, 'db:pg:hi', 'The target name should be from the target option';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Try passing the change.
ok $deploy->execute('widgets'), 'Execute with change';
ok $target->engine->with_verify, 'Engine should verify';
ok $target->engine->log_only, 'The engine should be set log_only';
is $target->engine->lock_timeout, 30, 'The lock timeout should be set to 30';
is_deeply \@args, ['foo', 'tag'],
    '"foo", "tag", and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many changes specified; deploying to "{change}"',
    change => 'foo',
)]], 'Should have too many changes warning';

# Pass the target.
ok $deploy->execute('db:pg:bye'), 'Execute with target again';
ok $target->engine->with_verify, 'Engine should verify';
ok $target->engine->log_only, 'The engine should be set log_only';
is $target->engine->lock_timeout, 30, 'The lock timeout should be set to 30';
is_deeply \@args, ['foo', 'tag'],
    '"foo", "tag", and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is $target->name, 'db:pg:hi', 'The target should be from the target option';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => 'db:pg:hi',
)]], 'Should have warning about too many targets';

# Make sure the mode enum works.
for my $mode (qw(all tag change)) {
    ok $CLASS->new( sqitch => $sqitch, mode => $mode ),
        qq{"$mode" should be a valid mode};
}

for my $bad (qw(foo bad gar)) {
    throws_ok {
        $CLASS->new( sqitch => $sqitch, mode => $bad )
    } qr/\QValue "$bad" did not pass type constraint "Enum[all,change,tag]/,
    qq{"$bad" should not be a valid mode};
}

# Make sure we get an exception for unknown args.
throws_ok { $deploy->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'deploy', 'Unknow arg ident should be "deploy"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    1,
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $deploy->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'deploy', 'Unknow args ident should be "deploy"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    2,
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

done_testing;
