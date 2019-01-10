#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 20;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Test::Warn;
use Config;
use File::Spec;
use Test::MockModule;
use Test::NoWarnings;
use lib 't/lib';
use TestConfig;

my $CLASS = 'App::Sqitch::Command::help';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = TestConfig->new;

isa_ok my $help = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'help',
    config  => $config,
}), $CLASS, 'Load help command';
isa_ok $help, 'App::Sqitch::Command', 'Help command';

can_ok $help, qw(
    options
    execute
    find_and_show
);

is_deeply [$CLASS->options], [qw(
    guide|g
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';


my $mock = Test::MockModule->new($CLASS);
my @args;
$mock->mock(_pod2usage => sub { @args = @_} );

ok $help->execute, 'Execute help';
is_deeply \@args, [
    $help,
    '-input'   => Pod::Find::pod_where({'-inc' => 1 }, 'sqitchcommands'),
    '-verbose' => 2,
    '-exitval' => 0,
], 'Should show sqitch app docs';

ok $help->execute('config'), 'Execute "config" help';
is_deeply \@args, [
    $help,
    '-input'   => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch-config'),
    '-verbose' => 2,
    '-exitval' => 0,
], 'Should show "config" command docs';

ok $help->execute('changes'), 'Execute "changes" help';
is_deeply \@args, [
    $help,
    '-input'   => Pod::Find::pod_where({'-inc' => 1 }, 'sqitchchanges'),
    '-verbose' => 2,
    '-exitval' => 0,
], 'Should show "changes" command docs';

ok $help->execute('tutorial'), 'Execute "tutorial" help';
is_deeply \@args, [
    $help,
    '-input'   => Pod::Find::pod_where({'-inc' => 1 }, 'sqitchtutorial'),
    '-verbose' => 2,
    '-exitval' => 0,
], 'Should show "tutorial" command docs';

my @fail;
$mock->mock(fail => sub { @fail = @_ });
throws_ok { $help->execute('nonexistent') } 'App::Sqitch::X',
    'Should get an exception for "nonexistent" help';
is $@->ident, 'help', 'Exception ident should be "help"';
is $@->message, __x(
    'No manual entry for {command}',
    command => 'sqitch-nonexistent',
), 'Should get failure message for nonexistent command';
is $@->exitval, 1, 'Exception exit val should be 1';
