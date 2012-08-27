#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 93;
use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use Path::Class;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_exists_ok file_not_exists_ok);
use Test::File::Contents;
use Locale::TextDomain qw(App-Sqitch);
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::bundle';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch object';
my $config = $sqitch->config;
isa_ok my $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'bundle command';

can_ok $CLASS, qw(
    configure
    execute
    dest_dir
    dest_top_dir
    dest_deploy_dir
    dest_revert_dir
    dest_test_dir
    bundle_config
    bundle_plan
    bundle_scripts
    _mkpath
    _copy_if_modified
);

is_deeply [$CLASS->options], [qw(
    dest_dir|dir=s
)], 'Should have dest_dir option';

is $bundle->dest_dir, dir('bundle'),
    'Default dest_dir should be bundle/';

is $bundle->dest_top_dir, dir('bundle'), 'Should have dest top dir';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {}, 'Default config should be empty';
is_deeply $CLASS->configure($config, {dest_dir => 'whu'}), {
    dest_dir => dir 'whu',
}, '--dest_dir should be converted to a path object by configure()';

chdir 't';
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'sql',
), 'Load a sqitch object with top_dir';
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
is $bundle->dest_top_dir, dir(qw(_build sql sql)),
    'Dest top dir should be _build/sql/sql/';
for my $sub (qw(deploy revert test)) {
    my $attr = "dest_$sub\_dir";
    is $bundle->$attr, $dir->subdir('sql', $sub),
        "Dest $sub dir should be _build/sql/sql/$sub";
}

# Try pg project.
ok $sqitch = App::Sqitch->new(
    top_dir => dir 'pg',
), 'Load a sqitch object with pg top_dir';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'pg bundle command';

is $bundle->dest_dir, $dir, qq{dest_dir should again be "$dir"};
for my $sub (qw(deploy revert test)) {
    my $attr = "dest_$sub\_dir";
    is $bundle->$attr, $dir->subdir('pg', $sub),
        "Dest $sub dir should be _build/sql/pg/$sub";
}

##############################################################################
# Test _mkpath.
my $path = dir 'delete.me';
dir_not_exists_ok $path, "Path $path should not exist";
END { remove_tree $path->stringify if -e $path }
ok $bundle->_mkpath($path), "Create $path";
dir_exists_ok $path, "Path $path should now exist";
is_deeply +MockOutput->get_debug, [[__x 'Created {file}', file => $path]],
    'The mkdir info should have been output';

# Create it again.
ok $bundle->_mkpath($path), "Create $path again";
dir_exists_ok $path, "Path $path should still exist";
is_deeply +MockOutput->get_debug, [], 'Nothing should have been emitted';

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

##############################################################################
# Test _copy().
my $file = file qw(sql deploy roles.sql);
my $dest = file $path, qw(deploy roles.sql);
file_not_exists_ok $dest, "File $dest should not exist";
ok $bundle->_copy_if_modified($file, $dest), "Copy $file to $dest";
file_exists_ok $dest, "File $dest should now exist";
file_contents_identical $dest, $file;
is_deeply +MockOutput->get_debug, [
    [__x 'Created {file}', file => $dest->dir],
    [__x(
        "Copying {source} -> {dest}",
        source => $file,
        dest   => $dest
    )],
], 'The mkdir and copy info should have been output';

# Copy it again.
ok $bundle->_copy_if_modified($file, $dest), "Copy $file to $dest again";
file_exists_ok $dest, "File $dest should still exist";
file_contents_identical $dest, $file;
is_deeply +MockOutput->get_debug, [], 'Should have no mkdir output';
is_deeply +MockOutput->get_debug, [], 'No copy message should have been emitted';

# Make it old and copy it again.
utime 0, $file->stat->mtime - 1, $dest;
ok $bundle->_copy_if_modified($file, $dest), "Copy $file to old $dest";
file_exists_ok $dest, "File $dest should still be there";
file_contents_identical $dest, $file;
is_deeply +MockOutput->get_debug, [[__x(
    "Copying {source} -> {dest}",
    source => $file,
    dest   => $dest
)]], 'Only copy message should again have been emitted';

# Copy a different file.
my $file2 = file qw(sql deploy users.sql);
$dest->remove;
ok $bundle->_copy_if_modified($file2, $dest), "Copy $file2 to $dest";
file_exists_ok $dest, "File $dest should now exist";
file_contents_identical $dest, $file2;
is_deeply +MockOutput->get_debug, [[__x(
    "Copying {source} -> {dest}",
    source => $file2,
    dest   => $dest
)]], 'Again only Copy message should have been emitted';

# Try to copy a nonexistent file.
my $nonfile = file 'nonexistent.txt';
throws_ok { $bundle->_copy_if_modified($nonfile, $dest) } 'App::Sqitch::X',
    'Should get exception when source file does not exist';
is $@->ident, 'bundle', 'Nonexistent file error ident should be "bundle"';
is $@->message, __x(
    'Cannot copy {file}: does not exist',
    file => $nonfile,
), 'Nonexistent file error message should be correct';

COPYDIE: {
    # Make copy die.
    $dest->remove;
    my $mocker = Test::MockModule->new('File::Copy');
    $mocker->mock(copy => sub { return 0 });
    throws_ok { $bundle->_copy_if_modified($file, $dest) } 'App::Sqitch::X',
        'Should get exception when copy returns false';
    is $@->ident, 'bundle', 'Copy fail ident should be "bundle"';
    is $@->message, __x(
        'Cannot copy "{source}" to "{dest}": {error}',
        source => $file,
        dest   => $dest,
        error  => $!,
    ), 'Copy fail error message should be correct';
}

##############################################################################
# Test bundle_config().
END { remove_tree $dir->parent->stringify }
$dest = file $dir, qw(sqitch.conf);
file_not_exists_ok $dest;
ok $bundle->bundle_config, 'Bundle the config file';
file_exists_ok $dest;
file_contents_identical file('sqitch.conf'), $dest;
is_deeply +MockOutput->get_info, [[__ 'Writing config']],
    'Should have config notice';

##############################################################################
# Test bundle_plan().
$dest = file $bundle->dest_top_dir, qw(sqitch.plan);
file_not_exists_ok $dest;
ok $bundle->bundle_plan, 'Bundle the plan file';
file_exists_ok $dest;
file_contents_identical file(qw(pg sqitch.plan)), $dest;
is_deeply +MockOutput->get_info, [[__ 'Writing plan']],
    'Should have plan notice';

##############################################################################
# Test bundle_scripts().
my @files = (
    $bundle->dest_deploy_dir->file('users.sql'),
    $bundle->dest_deploy_dir->file('widgets.sql'),
    $bundle->dest_revert_dir->file('users.sql'),
    $bundle->dest_revert_dir->file('widgets.sql'),
);
file_not_exists_ok $_ for @files;
ok $sqitch = App::Sqitch->new(
    extension => 'sql',
    top_dir   => dir 'pg',
), 'Load pg sqitch object';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another bundle command';
ok $bundle->bundle_scripts, 'Bundle scripts';
file_exists_ok $_ for @files;
is_deeply +MockOutput->get_info, [
    [__ 'Writing scripts'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets'],
], 'Should have change notices';

##############################################################################
# Test execute().
MockOutput->get_debug;
remove_tree $dir->parent->stringify;
@files = (
    file($dir, 'sqitch.conf'),
    file($bundle->dest_top_dir, 'sqitch.plan'),
    @files,
);
file_not_exists_ok $_ for @files;
ok $bundle->execute, 'Execute!';
file_exists_ok $_ for @files;
is_deeply +MockOutput->get_info, [
    [__x 'Bundling into {dir}', dir => $bundle->dest_dir ],
    [__ 'Writing config'],
    [__ 'Writing plan'],
    [__ 'Writing scripts'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets'],
], 'Should have all notices';

