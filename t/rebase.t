#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use Test::MockModule;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::rebase';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    onto_change
    upto_change
    log_only
    execute
    deploy_variables
    revert_variables
);

is_deeply [$CLASS->options], [qw(
    onto-change|onto=s
    upto-change|upto=s
    onto-target=s
    upto-target=s
    target|t=s
    mode=s
    verify!
    set|s=s%
    set-deploy|d=s%
    set-revert|r=s%
    log-only
    y
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    options => {
        engine    => 'sqlite',
        plan_file => file(qw(t sql sqitch.plan))->stringify,
        top_dir   => dir(qw(t sql))->stringify,
    }
);

my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}),
    { no_prompt => 0, verify => 0, mode => 'all', prompt_accept => 1 },
    'Should have empty default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
}), {
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    mode             => 'all',
    deploy_variables => { foo => 'bar' },
    revert_variables => { foo => 'bar' },
}, 'Should have set option';

is_deeply $CLASS->configure($config, {
    y           => 1,
    set_deploy  => { foo => 'bar' },
    log_only    => 1,
    verify      => 1,
    mode        => 'tag',
}), {
    mode             => 'tag',
    no_prompt        => 1,
    prompt_accept    => 1,
    deploy_variables => { foo => 'bar' },
    verify           => 1,
    log_only         => 1,
}, 'Should have mode, deploy_variables, verify, no_prompt, and log_only';

is_deeply $CLASS->configure($config, {
    y           => 0,
    set_revert  => { foo => 'bar' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    revert_variables => { foo => 'bar' },
}, 'Should have set_revert option and no_prompt false';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { foo => 'dep', hi => 'you' },
    set_revert => { foo => 'rev', hi => 'me' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    deploy_variables => { foo => 'dep', hi => 'you' },
    revert_variables => { foo => 'rev', hi => 'me' },
}, 'set_deploy and set_revert should overrid set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { hi => 'me' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', hi => 'me' },
}, 'set_deploy and set_revert should merge with set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { my => 'yo' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
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

    is_deeply $CLASS->configure($config, {}),
        {no_prompt => 0, verify => 0, mode => 'all', prompt_accept => 1},
        'Should have deploy configuration';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        onto_target => 'whu',
        set         => { foo => 'yo', yo => 'stellar' },
    }), {
        mode             => 'all',
        no_prompt        => 0,
        prompt_accept    => 1,
        verify           => 0,
        deploy_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        onto_change      => 'whu',
    }, 'Should have merged variables';
    is_deeply +MockOutput->get_warn, [[__x(
        'Option --{old} has been deprecated; use --{new} instead',
        old => 'onto-target',
        new => 'onto-change',
    )]], 'Should get warning for deprecated --onto-target';

    # Try merging with rebase.variables, too.
    $config_vals{'revert.variables'} = { hi => 42 };
    is_deeply $CLASS->configure($config, {
        set  => { yo => 'stellar' },
    }), {
        mode             => 'all',
        no_prompt        => 0,
        prompt_accept    => 1,
        verify           => 0,
        deploy_variables => { foo => 'bar', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'bar', yo => 'stellar', hi => 42 },
    }, 'Should have merged --set, deploy, rebase';

    isa_ok my $rebase = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $rebase->deploy_variables, { foo => 'bar', hi => 21 },
        'Should pick up deploy variables from configuration';

    is_deeply $rebase->revert_variables, { foo => 'bar', hi => 42 },
        'Should pick up revert variables from configuration';

    # Make sure we can override mode, prompting, and verify.
    %config_vals = (
        'revert.no_prompt'     => 1,
        'revert.prompt_accept' => 0,
        'deploy.verify'        => 1,
        'deploy.mode'          => 'tag',
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 1,
        prompt_accept => 0,
        verify        => 1,
        mode          => 'tag',
    }, 'Should have no_prompt true';

    # Rebase option takes precendence
    $config_vals{'rebase.no_prompt'}     = 0;
    $config_vals{'rebase.prompt_accept'} = 1;
    $config_vals{'rebase.verify'}        = 0;
    $config_vals{'rebase.mode'}          = 'change';
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 0,
        mode          => 'change',
    }, 'Should have false no_prompt, verify, and true prompt_accept from rebase config';

    delete $config_vals{'revert.no_prompt'};
    delete $config_vals{'revert.prompt_accept'};
    delete $config_vals{'rebase.verify'};
    delete $config_vals{'rebase.mode'};
    $config_vals{'rebase.no_prompt'} = 1;
    $config_vals{'rebase.prompt_accept'} = 0;
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 1,
        prompt_accept => 0,
        verify        => 1,
        mode          => 'tag',
    }, 'Should have true no_prompt, verify, and false prompt_accept from rebase from deploy';


    # But option should override.
    is_deeply $CLASS->configure($config, {y => 0, verify => 0, mode => 'all'}),
        { no_prompt => 0, verify => 0, mode => 'all', prompt_accept => 0 },
        'Should have no_prompt, prompt_accept false and mode all again';

    $config_vals{'revert.no_prompt'} = 0;
    $config_vals{'revert.prompt_accept'} = 1;
    delete $config_vals{'rebase.no_prompt'};
    delete $config_vals{'rebase.prompt_accept'};
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
    }, 'Should have no_prompt false and prompt_accept true for revert config';

    is_deeply $CLASS->configure($config, {y => 1}), {
        no_prompt     => 1,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
    }, 'Should have no_prompt true with -y';
}

##############################################################################
# Test accessors.
isa_ok my $rebase = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new status with target';
is $rebase->target, 'foo', 'Should have target "foo"';

isa_ok $rebase = $CLASS->new(sqitch => $sqitch), $CLASS;
is $rebase->target,      undef, 'Should have undef target';
is $rebase->onto_change, undef, 'onto_change should be undef';
is $rebase->upto_change, undef, 'upto_change should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @dep_args;
$mock_engine->mock(deploy => sub { shift; @dep_args = @_ });
my @rev_args;
$mock_engine->mock(revert => sub { shift; @rev_args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });

my $mock_cmd = Test::MockModule->new($CLASS);
my ($target, $orig_method);
$mock_cmd->mock(parse_args => sub {
    my %ret = shift->$orig_method(@_);
    $target = $ret{targets}[0];
    %ret;
});
$orig_method = $mock_cmd->original('parse_args');

ok $rebase->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@rev_args, ['@alpha'],
    '"@alpha" should be passed to the engine revert';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass a target.
ok $rebase->execute('db:sqlite:yow'), 'Execute with target';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@rev_args, [undef],
    'undef should be passed to the engine revert';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass both.
ok $rebase->execute('db:sqlite:yow', 'widgets'), 'Execute with onto and target';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@rev_args, ['widgets'],
    '"widgets" should be passed to the engine revert';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass all three!
ok $rebase->execute('db:sqlite:yow', 'roles', 'widgets'),
    'Execute with three args';
is_deeply \@dep_args, ['widgets', 'all'],
    '"widgets", and "all" should be passed to the engine deploy';
is_deeply \@rev_args, ['roles'],
    '"roles" should be passed to the engine revert';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass no args.
@dep_args = @rev_args = ();
ok $rebase->execute, 'Execute';
is_deeply \@dep_args, [undef, 'all'],
    'undef and "all" should be passed to the engine deploy';
is_deeply \@rev_args, [undef],
    'undef and = should be passed to the engine revert';
is_deeply \@vars, [],
    'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Mix it up with options.
isa_ok $rebase = $CLASS->new(
    target           => 'db:sqlite:lolwut',
    no_prompt        => 1,
    log_only         => 1,
    verify           => 1,
    sqitch           => $sqitch,
    mode             => 'tag',
    onto_change      => 'foo',
    upto_change      => 'bar',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

@dep_args = @rev_args = ();
ok $rebase->execute, 'Execute again';
is $target->name, 'db:sqlite:lolwut', 'Target name should be from option';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
ok $target->engine->with_verify, 'Engine should verify';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is_deeply \@rev_args, ['foo'], '"foo" and 1 should be passed to the engine revert';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Make sure we get warnings for too many things.
@dep_args = @rev_args, @vars = ();
ok $rebase->execute('db:sqlite:yow', 'roles', 'widgets'),
    'Execute with three args';
is $target->name, 'db:sqlite:lolwut', 'Target name should be from option';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
ok $target->engine->with_verify, 'Engine should verify';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is_deeply \@rev_args, ['foo'], '"foo" and 1 should be passed to the engine revert';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => 'db:sqlite:lolwut',
)], [__x(
    'Too many changes specified; rebasing onto "{onto}" up to "{upto}"',
    onto => 'foo',
    upto => 'bar',
)]], 'Should have two warnings';

# Make sure we get an exception for unknown args.
throws_ok { $rebase->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'rebase', 'Unknow arg ident should be "rebase"';
is $@->message, __x(
    'Unknown argument "{arg}"',
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $rebase->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'rebase', 'Unknow args ident should be "rebase"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

# If nothing is deployed, or we are already at the revert target, the revert
# should be skipped.
@dep_args = @rev_args = @vars = ();
$mock_engine->mock(revert => sub { hurl { ident => 'revert', message => 'foo', exitval => 1 } });
ok $rebase->execute, 'Execute once more';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_info, [['foo']],
    'Should have emitted info for non-fatal revert exception';

# Should die for fatal, unknown, or confirmation errors.
for my $spec (
    [ confirm => App::Sqitch::X->new(ident => 'revert:confirm', message => 'foo', exitval => 1) ],
    [ fatal   => App::Sqitch::X->new(ident => 'revert', message => 'foo', exitval => 2) ],
    [ unknown => bless { } => __PACKAGE__ ],
) {
    $mock_engine->mock(revert => sub { die $spec->[1] });
    throws_ok { $rebase->execute } ref $spec->[1],
        "Should rethrow $spec->[0] exception";
}

done_testing;
