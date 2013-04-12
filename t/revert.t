#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::revert';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    to_target
    log_only
    execute
    variables
);

is_deeply [$CLASS->options], [qw(
    to-target|to|target=s
    set|s=s%
    log-only
    y
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);

my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), { no_prompt => 0 },
    'Should have empty default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    y    => 1,
    set  => { foo => 'bar' },
}), {
    no_prompt => 1,
    variables => { foo => 'bar' },
}, 'Should have set option';

CONFIG: {
    my $mock_config = Test::MockModule->new(ref $config);
    my %config_vals;
    $mock_config->mock(get => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{key} };
    });
    $mock_config->mock(get_section => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{section} } || {};
    });
    %config_vals = (
        'deploy.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), { no_prompt => 0 },
        'Should have no_prompt false';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        to_target => 'whu',
        log_only  => 1,
        set       => { foo => 'yo', yo => 'stellar' },
    }), {
        no_prompt => 0,
        variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        to_target => 'whu',
        log_only  => 1,
    }, 'Should have merged variables';

    # Try merging with revert.variables, too.
    $config_vals{'revert.variables'} = { hi => 42 };
    is_deeply $CLASS->configure($config, {
        set  => { yo => 'stellar' },
    }), {
        no_prompt => 0,
        variables => { foo => 'bar', yo => 'stellar', hi => 42 },
    }, 'Should have merged --set, deploy, revert';

    isa_ok my $revert = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $revert->variables, { foo => 'bar', hi => 42 },
        'Should pick up variables from configuration';

    # Make sure we can override prompting.
    %config_vals = ('revert.no_prompt' => 1);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 1 },
        'Should have no_prompt true';

    # But option should override.
    is_deeply $CLASS->configure($config, {y => 0}), { no_prompt => 0 },
        'Should have no_prompt false again';

    %config_vals = ('revert.no_prompt' => 0);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 0 },
        'Should have no_prompt false for false config';

    is_deeply $CLASS->configure($config, {y => 1}), { no_prompt => 1 },
        'Should have no_prompt true with -y';
}

isa_ok my $revert = $CLASS->new(sqitch => $sqitch, no_prompt => 1), $CLASS;

is $revert->to_target, undef, 'to_target should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(revert => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $revert->execute('@alpha'), 'Execute to "@alpha"';
ok $sqitch->engine->no_prompt, 'Engine should be no_prompt';
is_deeply \@args, ['@alpha', 0],
    '"@alpha" and "all" should be passed to the engine';

@args = ();
ok $revert->execute, 'Execute';
is_deeply \@args, [undef, 0],
    'undef and "all" should be passed to the engine';
is_deeply {@vars}, { },
    'No vars should have been passed through to the engine';

isa_ok $revert = $CLASS->new(
    sqitch    => $sqitch,
    to_target => 'foo',
    log_only  => 1,
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with to and variables';

@args = ();
ok $revert->execute, 'Execute again';
ok !$sqitch->engine->no_prompt, 'Engine should not be no_prompt';
is_deeply \@args, ['foo', 1],
    '"foo" and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';

done_testing;
