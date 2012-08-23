#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 5;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::bundle';

chdir 't';
ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new(qw(t sql)),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $tag = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'bundle command';

can_ok $CLASS, qw(
    dest_dir
    configure
    execute
);

is_deeply [$CLASS->options], [qw(
    dest_dir|dir=s
)], 'Should have dest_dir option';
