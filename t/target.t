#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 4;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::target';

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('test-target'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $tag = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'target',
    config  => $config,
}), $CLASS, 'target command';

can_ok $CLASS, qw(
    options
    configure
    execute
);
