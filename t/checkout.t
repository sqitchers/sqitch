#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Locale::TextDomain qw(App-Sqitch);
use Test::MockModule;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::checkout';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    log_only
    execute
    deploy_variables
    revert_variables
);

is_deeply [$CLASS->options], [qw(
    mode=s
    set|s=s%
    set-deploy|d=s%
    set-revert|r=s%
    log-only
    verify!
)], 'Options should be correct';

my $tmp_git_dir = File::Temp->newdir();

ok my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine => 'sqlite',
), 'Load a sqitch object';

my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), {
    verify   => 0,
    mode     => 'all',
    log_only => 0,
}, 'Check default configuration';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
}, {}), {
    verify           => 0,
    log_only         => 0,
    mode             => 'all',
    deploy_variables => { foo => 'bar' },
    revert_variables => { foo => 'bar' },
}, 'Should have set option';


isa_ok my $checkout = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'checkout',
    config  => $config,
}), $CLASS, 'checkout command';

is_deeply $CLASS->configure($config, {
    set_deploy  => { foo => 'bar' },
    log_only    => 1,
    verify      => 1,
    mode        => 'tag',
}, {}), {
    mode             => 'tag',
    deploy_variables => { foo => 'bar' },
    verify           => 1,
    log_only         => 1,
}, 'Should have mode, deploy_variables, verify, and log_only';

is_deeply $CLASS->configure($config, {
    set_revert  => { foo => 'bar' },
}, {}), {
    mode             => 'all',
    verify           => 0,
    log_only         => 0,
    revert_variables => { foo => 'bar' },
}, 'Should have set_revert option false';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { foo => 'dep', hi => 'you' },
    set_revert => { foo => 'rev', hi => 'me' },
}, {}), {
    mode             => 'all',
    verify           => 0,
    log_only         => 0,
    deploy_variables => { foo => 'dep', hi => 'you' },
    revert_variables => { foo => 'rev', hi => 'me' },
}, 'set_deploy and set_revert should overrid set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { hi => 'me' },
}, {}), {
    mode             => 'all',
    log_only         => 0,
    verify           => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', hi => 'me' },
}, 'set_deploy and set_revert should merge with set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { my => 'yo' },
}, {}), {
    mode             => 'all',
    log_only         => 0,
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

    is_deeply $CLASS->configure($config, {}, {}), {log_only => 0, verify => 0, mode => 'all'},
        'Should have deploy configuration';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        set         => { foo => 'yo', yo => 'stellar' },
    }, {}), {
        mode             => 'all',
        log_only         => 0,
        verify           => 0,
        deploy_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'yo', yo => 'stellar', hi => 21 },
    }, 'Should have merged variables';

    # Try merging with checkout.variables, too.
    $config_vals{'revert.variables'} = { hi => 42 };
    is_deeply $CLASS->configure($config, {
        set  => { yo => 'stellar' },
    }, {}), {
        mode             => 'all',
        log_only        => 0,
        verify           => 0,
        deploy_variables => { foo => 'bar', yo => 'stellar', hi => 21 },
        revert_variables => { foo => 'bar', yo => 'stellar', hi => 42 },
    }, 'Should have merged --set, deploy, checkout';

    isa_ok my $checkout = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $checkout->deploy_variables, { foo => 'bar', hi => 21 },
        'Should pick up deploy variables from configuration';

    is_deeply $checkout->revert_variables, { foo => 'bar', hi => 42 },
        'Should pick up revert variables from configuration';

    # Make sure we can override mode, prompting, and verify.
    %config_vals = ('deploy.verify' => 1, 'deploy.mode' => 'tag');
    is_deeply $CLASS->configure($config, {}, {}), { log_only => 0, verify => 1, mode => 'tag' },
        'Should have log_only true';

    # Checkout option takes precendence
    $config_vals{'checkout.verify'} = 0;
    $config_vals{'checkout.mode'}   = 'change';
    is_deeply $CLASS->configure($config, {}, {}), { log_only => 0, verify => 0, mode => 'change' },
        'Should havev false log_only and verify from checkout config';

    delete $config_vals{'checkout.verify'};
    delete $config_vals{'checkout.mode'};
    is_deeply $CLASS->configure($config, {}, {}), { log_only => 0, verify => 1, mode => 'tag' },
        'Should have log_only true from checkout and verify from deploy';

    # But option should override.
    is_deeply $CLASS->configure($config, {verify => 0, mode => 'all'}, {}),
        { log_only => 0, verify => 0, mode => 'all' },
        'Should have log_only false and mode all again';

    is_deeply $CLASS->configure($config, {}, {}), { log_only => 0, verify => 1, mode => 'tag' },
        'Should have log_only false for false config';
}

# Mock the Git interface.
my $mock_git = Test::MockModule->new('Git::Wrapper');
my (@rev_parse_args, $rev_parsed);
$mock_git->mock(rev_parse => sub { shift; @rev_parse_args = @_; $rev_parsed });
my @checkout_args;
$mock_git->mock(checkout => sub { shift; @checkout_args = @_ });

# Try rebasing to the current branch.
$rev_parsed = 'fixdupes';
throws_ok { $checkout->execute($rev_parsed) } 'App::Sqitch::X',
    'Should get an error current branch';
is $@->ident, 'checkout', 'Current branch error ident should be "checkout"';
is $@->message, __x('Already on branch {branch}', branch => $rev_parsed),
    'Should get proper error for current branch error';
is_deeply \@rev_parse_args, [qw(--abbrev-ref HEAD)],
    'The proper args should have been passed to rev-parse';
@rev_parse_args = ();

# Should die when the plan file does not exist.
my $mock_sqitch = Test::MockModule->new(ref $sqitch);
$mock_sqitch->mock(plan_file => file 'nonesuch.plan');
throws_ok { $checkout->execute('master') } 'Git::Wrapper::Exception',
    'Should get an exception for a non-existent plan file';
is $@->status, 128, 'Exitval should be 128';
is $@->error, "fatal: Path 'nonesuch.plan' does not exist in 'master'\n",
     'Should have the proper error output';
$mock_sqitch->unmock('plan_file');

# Try a plan with nothing in common with the current branch's plan.
my (@show_args, $showed);
$mock_git->mock(show => sub { shift; @show_args = @_; $showed });
$showed = q{%project=sql

foo 2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>
bar 2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>
};

throws_ok { $checkout->execute('master') } 'App::Sqitch::X',
    'Should get an error for plans without a common change';
is $@->ident, 'checkout',
    'The no common change error ident should be "checkout"';
is $@->message, __x(
    'Target branch {target} has no canges in common with source branch {source}',
    target => 'master',
    source => $rev_parsed,
), 'The no common change error message should be correct';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my (@dep_args, @dep_changes);
$mock_engine->mock(deploy => sub {
    @dep_changes = map { $_->name } shift->plan->changes;
    @dep_args = @_;
});

my (@rev_args, @rev_changes);
$mock_engine->mock(revert => sub {
    @rev_changes = map { $_->name } shift->plan->changes;
    @rev_args = @_;
 });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });

# Load up the plan file without decoding and change the plan.
$showed = file(qw(t sql sqitch.plan))->slurp;
{
    no utf8;
    $showed =~ s/widgets/thingíes/;
}

# Checkout with options.
isa_ok $checkout = $CLASS->new(
    log_only         => 1,
    verify           => 1,
    sqitch           => $sqitch,
    mode             => 'tag',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

ok $checkout->execute('master'), 'Checkout master';
is_deeply \@rev_parse_args, [qw(--abbrev-ref HEAD)],
    'The proper args should again have been passed to rev-parse';
is_deeply \@show_args, ['master:' . $sqitch->plan_file ],
    'Should have requested the plan file contents as of master';
is_deeply \@checkout_args, ['master'], 'Should have checked out other branch';

is_deeply +MockOutput->get_info, [[__x(
    'Last change before the branches diverged: {last_change}',
    last_change => 'users @alpha',
)]], 'Should have emitted info identifying the last common change';

# Did it revert?
is_deeply \@rev_args, [$sqitch->plan->get('users')->id, 1],
    '"users" ID and 1 should be passed to the engine revert';
is_deeply \@rev_changes, [qw(roles users widgets)],
    'Should have had the current changes for revision';

# Did it deploy?
is_deeply \@dep_args, [undef, 'tag', 1],
    'undef, "tag", and 1 should be passed to the engine deploy';
is_deeply \@dep_changes, [qw(roles users thingíes)],
    'Should have had the other branch changes (decoded) for deploy';

ok $sqitch->engine->with_verify, 'Engine should verify';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';

done_testing;
