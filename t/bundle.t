#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 12;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::bundle';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $bundle = App::Sqitch::Command->load({
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

is $bundle->dest_dir, Path::Class::Dir->new('bundle'),
    'Default dest_dir should be bundle/';

##############################################################################
# Test configure().

is_deeply $CLASS->configure($config, {}), {}, 'Default config should be empty';
is_deeply $CLASS->configure($config, {dest_dir => 'whu'}), {
    dest_dir => Path::Class::Dir->new('whu'),
}, '--dest_dir should be converted to a path object by configure()';

chdir 't';
ok $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new(qw(sql)),
), 'Load a sqitch sqitch object with top_dir';
$config = $sqitch->config;
my $dir = Path::Class::Dir->new(qw(_build sql));
is_deeply $CLASS->configure($config, {}), {
    dest_dir => $dir,
}, 'bundle.dest_dir config should be converted to a path object by configure()';

##############################################################################
# Load a real project.
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another bundle command';

is $bundle->dest_dir, $dir, qq{dest_dir should be "$dir"};
