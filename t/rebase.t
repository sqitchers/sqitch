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

my $CLASS = 'App::Sqitch::Command::rebase';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    onto_target
    upto_target
    log_only
    execute
    deploy_variables
    revert_variables
);

is_deeply [$CLASS->options], [qw(
    onto-target|onto=s
    upto-target|upto=s
    set|s=s%
    set-deploy|d=s%
    set-revert|r=s%
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
    set  => { foo => 'bar' },
}), {
    no_prompt        => 0,
    deploy_variables => { foo => 'bar' },
    revert_variables => { foo => 'bar' },
}, 'Should have set option';

is_deeply $CLASS->configure($config, {
    y           => 1,
    set_deploy  => { foo => 'bar' },
    log_only    => 1,
}), {
    no_prompt        => 1,
    deploy_variables => { foo => 'bar' },
    log_only    => 1,
}, 'Should have deploy_veariables, no_propmt, and log_only';

is_deeply $CLASS->configure($config, {
    y           => 0,
    set_revert  => { foo => 'bar' },
}), {
    no_prompt        => 0,
    revert_variables => { foo => 'bar' },
}, 'Should have set_revert option and no_prompt false';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { foo => 'dep', hi => 'you' },
    set_revert => { foo => 'rev', hi => 'me' },
}), {
    no_prompt        => 0,
    deploy_variables => { foo => 'dep', hi => 'you' },
    revert_variables => { foo => 'rev', hi => 'me' },
}, 'set_deploy and set_revert should overrid set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { hi => 'me' },
}), {
    no_prompt        => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', hi => 'me' },
}, 'set_deploy and set_revert should merge with set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { my => 'yo' },
}), {
    no_prompt        => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', hi => 'you', my => 'yo' },
}, 'set_revert should merge with set_deploy';

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

    is_deeply $CLASS->configure($config, {}), {no_prompt => 0},
        'Should have mode configuration';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        onto_target => 'whu',
        set         => { foo => 'yo', yo => 'stellar' },
    }), {
        no_prompt        => 0,
        deploy_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        onto_target      => 'whu',
    }, 'Should have merged variables';

    # Try merging with rebase.variables, too.
    $config_vals{'revert.variables'} = { hi => 42 };
    is_deeply $CLASS->configure($config, {
        set  => { yo => 'stellar' },
    }), {
        no_prompt        => 0,
        deploy_variables => { foo => 'bar', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'bar', yo => 'stellar', hi => 42 },
    }, 'Should have merged --set, deploy, rebase';

    isa_ok my $rebase = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $rebase->deploy_variables, { foo => 'bar', hi => 21 },
        'Should pick up deploy variables from configuration';
    is_deeply $rebase->revert_variables, { foo => 'bar', hi => 42 },
        'Should pick up revert variables from configuration';

    # Make sure we can override prompting.
    %config_vals = ('revert.no_prompt' => 1);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 1 },
        'Should have no_prompt true';

    # Rebase option takes precencence
    %config_vals = ('rebase.no_prompt' => 0);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 0 },
        'Should have no_prompt false for rebase.no_prompt';

    delete $config_vals{'revert.no_prompt'};
    %config_vals = ('rebase.no_prompt' => 1);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 1 },
        'Should have no_prompt true from rebase.no_prompt';

    # But option should override.
    is_deeply $CLASS->configure($config, {y => 0}), { no_prompt => 0 },
        'Should have no_prompt false again';

    %config_vals = ('revert.no_prompt' => 0);
    is_deeply $CLASS->configure($config, {}), { no_prompt => 0 },
        'Should have no_prompt false for false config';

    is_deeply $CLASS->configure($config, {y => 1}), { no_prompt => 1 },
        'Should have no_prompt true with -y';
}

isa_ok my $rebase = $CLASS->new(sqitch => $sqitch), $CLASS;

is $rebase->onto_target, undef, 'onto_target should be undef';
is $rebase->upto_target, undef, 'upto_target should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @dep_args;
$mock_engine->mock(deploy => sub { shift; @dep_args = @_ });
my @rev_args;
$mock_engine->mock(revert => sub { shift; @rev_args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });

ok $rebase->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@dep_args, [undef, 0],
    'undef and 0 should be passed to the engine deploy';
is_deeply \@rev_args, ['@alpha', 0],
    '"@alpha" and 0 should be passed to the engine revert';
ok !$sqitch->engine->no_prompt, 'Engine should prompt';

@dep_args = @rev_args = ();
ok $rebase->execute, 'Execute';
is_deeply \@dep_args, [undef, 0],
    'undef and 0 should be passed to the engine deploy';
is_deeply \@rev_args, [undef, 0],
    'undef and = should be passed to the engine revert';
is_deeply \@vars, [],
    'No vars should have been passed through to the engine';

isa_ok $rebase = $CLASS->new(
    no_prompt        => 1,
    log_only         => 1,
    sqitch           => $sqitch,
    onto_target      => 'foo',
    upto_target      => 'bar',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

@dep_args = @rev_args = ();
ok $rebase->execute, 'Execute again';
ok $sqitch->engine->no_prompt, 'Engine should be no_prompt';
is_deeply \@dep_args, ['bar', 1], '"bar" and 1 should be passed to the engine revert';
is_deeply \@rev_args, ['foo', 1], '"foo" and 1 should be passed to the engine deploy';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';

done_testing;
