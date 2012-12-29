#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::verify';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    from_target
    to_target
    variables
);

is_deeply [$CLASS->options], [qw(
    from-target|from=s
    to-target|to=s
    set|s=s%
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);
my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), {
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    from_target => 'foo',
    to_target   => 'bar',
    set  => { foo => 'bar' },
}), {
    from_target => 'foo',
    to_target   => 'bar',
    variables   => { foo => 'bar' },
}, 'Should have targets and variables from options';

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
        'verify.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {},
        'Should have no config if no options';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        to_target => 'whu',
        set       => { foo => 'yo', yo => 'stellar' },
    }), {
        to_target => 'whu',
        variables => { foo => 'yo', yo => 'stellar', hi => 21 },
    }, 'Should have merged variables';

    isa_ok my $verify = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $verify->variables, { foo => 'bar', hi => 21 },
        'Should pick up variables from configuration';
}

isa_ok my $verify = $CLASS->new(sqitch => $sqitch), $CLASS;

is $verify->from_target, undef, 'from_target should be undef';
is $verify->to_target, undef, 'to_target should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(verify => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $verify->execute, 'Execute with nothing.';
is_deeply \@args, [undef, undef],
    'Two undefs should be passed to the engine';

ok $verify->execute('@alpha'), 'Execute from "@alpha"';
is_deeply \@args, ['@alpha', undef],
    '"@alpha" and undef should be passed to the engine';

ok $verify->execute('@alpha', '@beta'), 'Execute from "@alpha" to "@beta"';
is_deeply \@args, ['@alpha', '@beta'],
    '"@alpha" and "@beat" should be passed to the engine';

isa_ok $verify = $CLASS->new(
    sqitch      => $sqitch,
    from_target => 'foo',
    to_target   => 'bar',
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with from, to, and variables';

ok $verify->execute, 'Execute again';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';

ok $verify->execute('one', 'two'), 'Execute with command-line args';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';

done_testing;
