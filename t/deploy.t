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

my $CLASS = 'App::Sqitch::Command::deploy';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    to_target
    mode
    execute
    variables
);

is_deeply [$CLASS->options], [qw(
    to-target|to|target=s
    mode=s
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
    mode  => 'all',
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    mode => 'tag',
    set  => { foo => 'bar' },
}), {
    mode      => 'tag',
    variables => { foo => 'bar' },
}, 'Should have mode and set options';

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
        'deploy.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {
        mode  => 'change',
    }, 'Should have mode configuration';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        to_target => 'whu',
        mode      => 'tag',
        set       => { foo => 'yo', yo => 'stellar' },
    }), {
        to_target => 'whu',
        mode      => 'tag',
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
    '"@alpha" and "all" should be passed to the engine';

@args = ();
ok $deploy->execute, 'Execute';
is_deeply \@args, [undef, 'all'],
    'undef and "all" should be passed to the engine';

isa_ok $deploy = $CLASS->new(
    sqitch    => $sqitch,
    to_target => 'foo',
    mode      => 'tag',
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with to, mode, and variables';

@args = ();
ok $deploy->execute, 'Execute again';
is_deeply \@args, ['foo', 'tag'],
    '"foo" and "tag" should be passed to the engine';
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
