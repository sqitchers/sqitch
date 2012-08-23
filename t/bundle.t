#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 28;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use Path::Class;
use Test::Exception;
use Test::Dir;
use Locale::TextDomain qw(App-Sqitch);
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
    _mkpath
    bundle_config
    bundle_plan
    bundle_scripts
);

is_deeply [$CLASS->options], [qw(
    dest_dir|dir=s
)], 'Should have dest_dir option';

is $bundle->dest_dir, dir('bundle'),
    'Default dest_dir should be bundle/';

is_deeply $bundle->_dir_map, {
    top_dir => [ $sqitch->top_dir, dir 'bundle'],
}, 'Dir map should have only top dir';

##############################################################################
# Test configure().

is_deeply $CLASS->configure($config, {}), {}, 'Default config should be empty';
is_deeply $CLASS->configure($config, {dest_dir => 'whu'}), {
    dest_dir => dir 'whu',
}, '--dest_dir should be converted to a path object by configure()';

chdir 't';
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'sql',
), 'Load a sqitch sqitch object with top_dir';
$config = $sqitch->config;
my $dir = dir qw(_build sql);
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
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql sql)],
    deploy_dir => [ dir(qw(sql deploy)), dir(qw(_build sql sql deploy)) ]
}, 'Dir map should have top and deploy dirs';

# Try pg project.
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'pg',
), 'Load a sqitch sqitch object with pg top_dir';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'pg bundle command';

is $bundle->dest_dir, $dir, qq{dest_dir should again be "$dir"};
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
}, 'Dir map should have top, deploy, and revert dirs';

# Add a test directory.
my $test_dir = dir qw(pg test);
$test_dir->mkpath;
END { remove_tree $test_dir->stringify if -e $test_dir }
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another pg bundle command';
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
}, 'Dir map should still not have test dir';

# Now put something into the test directory.
$test_dir->file('something')->touch;
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'yet another pg bundle command';
is_deeply $bundle->_dir_map, {
    top_dir    => [ $sqitch->top_dir, dir qw(_build sql pg)],
    deploy_dir => [ dir(qw(pg deploy)), dir(qw(_build sql pg deploy)) ],
    revert_dir => [ dir(qw(pg revert)), dir(qw(_build sql pg revert)) ],
    test_dir   => [ dir(qw(pg test)),   dir(qw(_build sql pg test)) ],
}, 'Dir map should still now include test dir';

##############################################################################
# Test _mkpath.
my $path = dir 'delete.me';
dir_not_exists_ok $path, "Path $path should not exist";
END { remove_tree $path->stringify if -e $path }
ok $bundle->_mkpath($path), "Create $path";
dir_exists_ok $path, "Path $path should now exist";

# Handle errors.
FSERR: {
    # Make mkpath to insert an error.
    my $mock = Test::MockModule->new('File::Path');
    $mock->mock( mkpath => sub {
        my ($file, $p) = @_;
        ${ $p->{error} } = [{ $file => 'Permission denied yo'}];
        return;
    });

    throws_ok { $bundle->_mkpath('foo') } 'App::Sqitch::X',
        'Should fail on permission issue';
    is $@->ident, 'bundle', 'Permission error should have ident "bundle"';
    is $@->message, __x(
        'Error creating {path}: {error}',
        path  => 'foo',
        error => 'Permission denied yo',
    ), 'The permission error should be formatted properly';
}

