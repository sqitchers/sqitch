#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 11;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Config;
use File::Spec;
use Test::MockModule;
use Test::NoWarnings;

my $CLASS = 'App::Sqitch::Command::help';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = App::Sqitch::Config->new;
isa_ok my $help = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'help',
    config  => $config,
}), $CLASS, 'Load help command';

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
