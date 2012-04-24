#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 9;
#use Test::More 'no_plan';
use App::Sqitch;
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

# Make sure the script directory can be found by modifying Config.
my $perl_config = tied %Config::Config;
$perl_config->{scriptdir} = 'bin';

my $mock = Test::MockModule->new($CLASS);
my @args;
$mock->mock(_pod2usage => sub { @args = @_} );

ok $help->execute, 'Execute help';
is_deeply \@args, [
    $help,
    '-input'   => File::Spec->catfile(qw(bin sqitch)),
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
ok $help->execute('nonexistent'), 'Execute "nonexistent" help';
is_deeply \@fail, [$help, qq{No manual entry for sqitch-nonexistent\n}],
    'Should get failure message for nonexistent command';
