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
use Test::File qw(file_not_exists_ok file_exists_ok);

use File::Temp;
use File::Copy::Recursive qw(dircopy);
use lib 't/lib';
use Git::Wrapper;
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
    top_dir => Path::Class::dir($tmp_git_dir),
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
    is_deeply $CLASS->configure($config, {y => 0, verify => 0, mode => 'all'},
        {}),
        { log_only => 0, verify => 0, mode => 'all' },
        'Should have log_only false and mode all again';

    is_deeply $CLASS->configure($config, {}, {}), { log_only => 0, verify => 1, mode => 'tag' },
        'Should have log_only false for false config';

    is_deeply $CLASS->configure($config, {y => 1}, {}), { log_only => 0, verify => 1, mode => 'tag' },
        'Should have log_only true with -y';
}

# Copy the git repo to a temp directory
my $git = $checkout->git;

$git->clone(Path::Class::Dir->new('t', 'git', 'checkout'), $tmp_git_dir);


file_exists_ok file ($tmp_git_dir, 'sqitch.plan'),
    'The plan file exists';

file_exists_ok file ($tmp_git_dir, '.git'),
    'The repository exists';


my $plan = $sqitch->plan;
my $changes = $plan->changes;
is $changes, 2, "The plan file from the git repository is ok";
is $git->dir, $tmp_git_dir, 'Git is in the tmp dir';

# Make sure the local branches are actually created.
$git->checkout('another_branch');
$git->pull();
$git->checkout('yet_another_branch');
$git->pull();
$git->checkout('master');
$git->pull();

# Mock the engine
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @dep_args;
$mock_engine->mock(deploy => sub { shift; @dep_args = @_ });
my @rev_args;
$mock_engine->mock(revert => sub { shift; @rev_args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });

# Deploy the thing.
$sqitch->engine->deploy;

$checkout->execute('another_branch');

is_deeply +MockOutput->get_info, [
    [__x 'Last change before the branches diverged: {last_change}',
         last_change => 'users @alpha'],
], 'Should not revert anything, and deploy to another_branch';


throws_ok {$checkout->execute('another_branch')} 'App::Sqitch::X',
    'Should throw an error when switching to the same branch';

is $@->ident, 'checkout', 'The error when switching to the same branch should be ident';
is $@->message, __x('Already on branch {branch}',
         branch=> 'another_branch'), 'The error message should match';

$checkout->execute('yet_another_branch');
is_deeply +MockOutput->get_info, [
    [__x 'Last change before the branches diverged: {last_change}',
         last_change => 'users @alpha'],
], 'Should not revert anything, and deploy to another_branch';

done_testing;
