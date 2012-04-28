#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 3;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;

my $CLASS = 'App::Sqitch::Command::add_step';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = App::Sqitch::Config->new;
isa_ok my $add_step = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'add-step',
    config  => $config,
}), $CLASS, 'add_step command';
