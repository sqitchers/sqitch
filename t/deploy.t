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

my $CLASS = 'App::Sqitch::Command::deploy';
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
    mode
    log_only
    execute
    variables
);

is_deeply [$CLASS->options], [qw(
    to-target|to|target=s
    mode=s
    set|s=s%
    log-only
    verify!
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);
my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), {
    mode     => 'all',
    verify   => 0,
    log_only => 0,
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    mode => 'tag',
    verify => 1,
    log_only => 1,
    set  => { foo => 'bar' },
}), {
    mode      => 'tag',
    verify    => 1,
    log_only  => 1,
    variables => { foo => 'bar' },
}, 'Should have mode, verify, set, and log-only options';

CONFIG: {
    my $mock_config = Test::MockModule->new(ref $config);
    my %config_vals;
    $mock_config->mock(get => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{key} };
    });
    $mock_config->mock(get_section => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{section} };
    });
    %config_vals = (
        'deploy.mode'      => 'change',
        'deploy.verify'    => 1,
        'deploy.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {
        mode     => 'change',
        verify   => 1,
        log_only => 0,
    }, 'Should have mode and verify configuration';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        to_target => 'whu',
        mode      => 'tag',
        verify    => 0,
        set       => { foo => 'yo', yo => 'stellar' },
    }), {
        to_target => 'whu',
        mode      => 'tag',
        verify    => 0,
        log_only  => 0,
        variables => { foo => 'yo', yo => 'stellar', hi => 21 },
    }, 'Should have merged variables';

    isa_ok my $deploy = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $deploy->variables, { foo => 'bar', hi => 21 },
        'Should pick up variables from configuration';
}

isa_ok my $deploy = $CLASS->new(sqitch => $sqitch), $CLASS;

is $deploy->to_target, undef, 'to_target should be undef';
is $deploy->mode, 'all', 'mode should be "all"';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(deploy => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $deploy->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@args, ['@alpha', 'all'],
    '"@alpha" "all", and 0 should be passed to the engine';
ok !$sqitch->engine->log_only, 'The engine should not be set log_only';

@args = ();
ok $deploy->execute, 'Execute';
is_deeply \@args, [undef, 'all'],
    'undef, "all", and 0 should be passed to the engine';

isa_ok $deploy = $CLASS->new(
    sqitch    => $sqitch,
    to_target => 'foo',
    mode      => 'tag',
    log_only  => 1,
    verify    => 1,
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with to, mode, log_only, and variables';

@args = ();
ok $deploy->execute, 'Execute again';
ok $sqitch->engine->with_verify, 'Engine should verify';
ok $sqitch->engine->log_only, 'The engine should be set log_only';
is_deeply \@args, ['foo', 'tag'],
    '"foo", "tag", and 1 should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';

# Make sure the mode enum works.
for my $mode (qw(all tag change)) {
    ok $CLASS->new( sqitch => $sqitch, mode => $mode ),
        qq{"$mode" should be a valid mode};
}

for my $bad (qw(foo bad gar)) {
    throws_ok { $CLASS->new( sqitch => $sqitch, mode => $bad ) } qr/Validation failed/,
        qq{"$bad" should not be a valid mode};
}

done_testing;
