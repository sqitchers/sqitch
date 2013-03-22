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

my $tmp_git_dir = File::Temp->newdir();

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::dir($tmp_git_dir),
    _engine   => 'sqlite',
), 'Load a sqitch object';

my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), {
    verify => 0,
    mode => 'all',
    log_only => 0,
}, 'Check default configuration';

isa_ok my $checkout = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'checkout',
    config  => $config,
}), $CLASS, 'checkout command';


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
