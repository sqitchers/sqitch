#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use lib '/Users/david/dev/cpan/config-gitlike/lib';
use Test::More tests => 276;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_exists_ok file_not_exists_ok);
use Test::File::Contents;
use Locale::TextDomain qw(App-Sqitch);
use File::Path qw(make_path remove_tree);
use Test::NoWarnings;
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

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
    from
    to
    dest_dir
    dest_top_dir
    dest_deploy_dir
    dest_revert_dir
    dest_verify_dir
    bundle_config
    bundle_plan
    bundle_scripts
    _mkpath
    _copy_if_modified
);

is_deeply [$CLASS->options], [qw(
    dest-dir|dir=s
    all|a!
    from=s
    to=s
)], 'Should have dest_dir option';

is $bundle->dest_dir, dir('bundle'),
    'Default dest_dir should be bundle/';

is $bundle->dest_top_dir($bundle->default_target), dir('bundle'),
    'Should have dest top dir';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {}, 'Default config should be empty';
is_deeply $CLASS->configure($config, {dest_dir => 'whu'}), {
    dest_dir => dir 'whu',
}, '--dest_dir should be converted to a path object by configure()';

is_deeply $CLASS->configure($config, {from => 'HERE', to => 'THERE'}), {
    from => 'HERE',
    to   => 'THERE',
}, '--from and --to should be passed through configure';

chdir 't';
$ENV{SQITCH_CONFIG} = 'sqitch.conf';
END { remove_tree 'bundle' if -d 'bundle' }
ok $sqitch = App::Sqitch->new(
    options => { top_dir => dir('sql')->stringify },
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
is $bundle->dest_top_dir($bundle->default_target), dir(qw(_build sql sql)),
    'Dest top dir should be _build/sql/sql/';
my $target = $bundle->default_target;
for my $sub (qw(deploy revert verify)) {
    my $attr = "dest_$sub\_dir";
    is $bundle->$attr($target), $dir->subdir('sql', $sub),
        "Dest $sub dir should be _build/sql/sql/$sub";
}

# Try engine project.
ok $sqitch = App::Sqitch->new(
    options => { top_dir => dir('engine')->stringify },
), 'Load a sqitch object with engine top_dir';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'engine bundle command';
$target = $bundle->default_target;

is $bundle->dest_dir, $dir, qq{dest_dir should again be "$dir"};
for my $sub (qw(deploy revert verify)) {
    my $attr = "dest_$sub\_dir";
    is $bundle->$attr($target), $dir->subdir('engine', $sub),
        "Dest $sub dir should be _build/sql/engine/$sub";
}

##############################################################################
# Test _mkpath.
my $path = dir 'delete.me';
dir_not_exists_ok $path, "Path $path should not exist";
END { remove_tree $path->stringify if -e $path }
ok $bundle->_mkpath($path), "Create $path";
dir_exists_ok $path, "Path $path should now exist";
is_deeply +MockOutput->get_debug, [['    ', __x 'Created {file}', file => $path]],
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
    ['    ', __x 'Created {file}', file => $dest->dir],
    ['    ', __x(
        "Copying {source} -> {dest}",
        source => $file,
        dest   => $dest
    )],
], 'The mkdir and copy info should have been output';

# Copy it again.
ok $bundle->_copy_if_modified($file, $dest), "Copy $file to $dest again";
file_exists_ok $dest, "File $dest should still exist";
file_contents_identical $dest, $file;
my $out = MockOutput->get_debug;
is_deeply $out, [], 'Should have no debugging output' or diag explain $out;

# Make it old and copy it again.
utime 0, $file->stat->mtime - 1, $dest;
ok $bundle->_copy_if_modified($file, $dest), "Copy $file to old $dest";
file_exists_ok $dest, "File $dest should still be there";
file_contents_identical $dest, $file;
is_deeply +MockOutput->get_debug, [['    ', __x(
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
is_deeply +MockOutput->get_debug, [['    ', __x(
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
file_contents_identical $dest, file('sqitch.conf');
is_deeply +MockOutput->get_info, [[__ 'Writing config']],
    'Should have config notice';

##############################################################################
# Test bundle_plan().
$dest = file $bundle->dest_top_dir($bundle->default_target), qw(sqitch.plan);
file_not_exists_ok $dest;
ok $bundle->bundle_plan($bundle->default_target),
    'Bundle the default target plan file';
file_exists_ok $dest;
file_contents_identical $dest, file(qw(engine sqitch.plan));
is_deeply +MockOutput->get_info, [[__ 'Writing plan']],
    'Should have plan notice';

# Make sure that --from works.
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
    args    => ['--from', 'widgets'],
}), $CLASS, '--from bundle command';
is $bundle->from, 'widgets', 'From should be "widgets"';
ok $bundle->bundle_plan($bundle->default_target, 'widgets'),
    'Bundle the default target plan file with from arg';
my $plan = $bundle->default_target->plan;
is_deeply +MockOutput->get_info, [[__x(
    'Writing plan from {from} to {to}',
    from => 'widgets',
    to   => '@HEAD',
)]], 'Statement of the bits written should have been emitted';
file_contents_is $dest,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=engine' . "\n"
    . "\n"
    . $plan->find('widgets')->as_string . "\n"
    . $plan->find('func/add_user')->as_string . "\n",
    'Plan should have written only "widgets" and "func/add_user"';

# Make sure that --to works.
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
    args    => ['--to', 'users'],
}), $CLASS, '--to bundle command';
is $bundle->to, 'users', 'To should be "users"';
ok $bundle->bundle_plan($bundle->default_target, undef, 'users'),
    'Bundle the default target plan file with to arg';
is_deeply +MockOutput->get_info, [[__x(
    'Writing plan from {from} to {to}',
    from => '@ROOT',
    to   => 'users',
)]], 'Statement of the bits written should have been emitted';
file_contents_is $dest,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=engine' . "\n"
    . "\n"
    . $plan->find('users')->as_string . "\n"
    . join( "\n", map { $_->as_string } $plan->find('users')->tags ) . "\n",
    'Plan should have written only "users" and its tags';

##############################################################################
# Test bundle_scripts().
my @scripts = (
    $bundle->dest_deploy_dir($target)->file('users.sql'),
    $bundle->dest_revert_dir($target)->file('users.sql'),
    $bundle->dest_deploy_dir($target)->file('widgets.sql'),
    $bundle->dest_revert_dir($target)->file('widgets.sql'),
    $bundle->dest_deploy_dir($target)->file(qw(func add_user.sql)),
    $bundle->dest_revert_dir($target)->file(qw(func add_user.sql)),
);
file_not_exists_ok $_ for @scripts;
ok $sqitch = App::Sqitch->new(
    options => {
        extension => 'sql',
        top_dir   => dir('engine')->stringify,
    },
), 'Load engine sqitch object';
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another bundle command';
ok $bundle->bundle_scripts($bundle->default_target),
    'Bundle default target scripts';
file_exists_ok $_ for @scripts;
is_deeply +MockOutput->get_info, [
    [__ 'Writing scripts'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets'],
    ['  + ', 'func/add_user'],
], 'Should have change notices';

# Make sure that --from works.
remove_tree $dir->parent->stringify;
isa_ok $bundle = App::Sqitch::Command::bundle->new(
    sqitch   => $sqitch,
    dest_dir => $bundle->dest_dir,
    from     => 'widgets',
), $CLASS, 'bundle from "widgets"';
ok $bundle->bundle_scripts($bundle->default_target, 'widgets'), 'Bundle scripts';
file_not_exists_ok $_ for @scripts[0,1];
file_exists_ok $_ for @scripts[2,3];
is_deeply +MockOutput->get_info, [
    [__ 'Writing scripts'],
    ['  + ', 'widgets'],
    ['  + ', 'func/add_user'],
], 'Should have only "widets" in change notices';

# Make sure that --to works.
remove_tree $dir->parent->stringify;
isa_ok $bundle = App::Sqitch::Command::bundle->new(
    sqitch   => $sqitch,
    dest_dir => $bundle->dest_dir,
    to       => 'users',
), $CLASS, 'bundle to "users"';
ok $bundle->bundle_scripts($bundle->default_target, undef, 'users'), 'Bundle scripts';
file_exists_ok $_ for @scripts[0,1];
file_not_exists_ok $_ for @scripts[2,3];
is_deeply +MockOutput->get_info, [
    [__ 'Writing scripts'],
    ['  + ', 'users @alpha'],
], 'Should have only "users" in change notices';

# Should throw exceptions on unknonw changes.
for my $key (qw(from to)) {
    my $bundle = $CLASS->new( sqitch => $sqitch, $key => 'nonexistent' );
    throws_ok {
        $bundle->bundle_scripts($bundle->default_target, 'nonexistent')
    } 'App::Sqitch::X', "Should die on nonexistent $key change";
    is $@->ident, 'bundle', qq{Nonexistent $key change ident should be "bundle"};
    is $@->message, __x(
        'Cannot find change {change}',
        change => 'nonexistent',
    ), "Nonexistent $key message change should be correct";
}

##############################################################################
# Test execute().
MockOutput->get_debug;
remove_tree $dir->parent->stringify;
@scripts = (
    file($dir, 'sqitch.conf'),
    file($bundle->dest_top_dir($bundle->default_target), 'sqitch.plan'),
    @scripts,
);
file_not_exists_ok $_ for @scripts;
isa_ok $bundle = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'bundle',
    config  => $config,
}), $CLASS, 'another bundle command';
ok $bundle->execute, 'Execute!';
file_exists_ok $_ for @scripts;
is_deeply +MockOutput->get_info, [
    [__x 'Bundling into {dir}', dir => $bundle->dest_dir ],
    [__ 'Writing config'],
    [__ 'Writing plan'],
    [__ 'Writing scripts'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets'],
    ['  + ', 'func/add_user'],
], 'Should have all notices';

# Try a configuration with multiple plans.
my $multidir = $dir->parent;
END { remove_tree $multidir->stringify }
remove_tree $multidir->stringify;
my @sql = (
    $multidir->file(qw(sql sqitch.plan)),
    $multidir->file(qw(sql deploy roles.sql)),
    $multidir->file(qw(sql deploy users.sql)),
    $multidir->file(qw(sql verify users.sql)),
    $multidir->file(qw(sql deploy widgets.sql)),
);
my @engine = (
    $multidir->file(qw(engine sqitch.plan)),
    $multidir->file(qw(engine deploy users.sql)),
    $multidir->file(qw(engine revert users.sql)),
    $multidir->file(qw(engine deploy widgets.sql)),
    $multidir->file(qw(engine revert widgets.sql)),
    $multidir->file(qw(engine deploy func add_user.sql)),
    $multidir->file(qw(engine revert func add_user.sql)),
);
my $conf_file = $multidir->file('multiplan.conf'),;
file_not_exists_ok $_ for ($conf_file, @sql, @engine);

local $ENV{SQITCH_CONFIG} = 'multiplan.conf';
$sqitch = App::Sqitch->new;
isa_ok $bundle = $CLASS->new(
    sqitch  => $sqitch,
    config  => $sqitch->config,
    all     => 1,
    dest_dir => dir '_build',
), $CLASS, 'all xmultiplan bundle command';
ok $bundle->execute, 'Execute multi-target bundle!';
file_exists_ok $_ for ($conf_file, @sql, @engine);

# Make sure we get an error with both --all and a specified target.
throws_ok { $bundle->execute('pg' ) } 'App::Sqitch::X',
    'Should get an error for --all and a target arg';
is $@->ident, 'bundle', 'Mixed arguments error ident should be "bundle"';
is $@->message, __(
    'Cannot specify both --all and engine, target, or plan arugments'
), 'Mixed arguments error message should be correct';

# Try without --all.
isa_ok $bundle = $CLASS->new(
    sqitch  => $sqitch,
    config  => $sqitch->config,
    dest_dir => dir '_build',
), $CLASS, 'multiplan bundle command';
remove_tree $multidir->stringify;
ok $bundle->execute, qq{Execute with no arg};
file_exists_ok $_ for ($conf_file, @engine);
file_not_exists_ok $_ for @sql;

# Make sure it works with bundle.all set, as well.
my $cmock = Test::MockModule->new('App::Sqitch::Config');
my $get;
$cmock->mock( get => sub {
    return 1 if $_[2] eq 'bundle.all';
    return $get->(@_);
});
$get = $cmock->original('get');
remove_tree $multidir->stringify;
ok $bundle->execute, qq{Execute with bundle.all config};
file_exists_ok $_ for ($conf_file, @engine, @sql);
$cmock->unmock_all;

# Try limiting it in various ways.
for my $spec (
    [
        target => 'pg',
        { include => \@engine, exclude => \@sql },
    ],
    [
        'plan file' => file(qw(engine sqitch.plan))->stringify,
        { include => \@engine, exclude => \@sql },
    ],
    [
        target => 'mysql',
        { include => \@sql, exclude => \@engine },
    ],
    [
        'plan file' => file(qw(sql sqitch.plan))->stringify,
        { include => \@sql, exclude => \@engine },
    ],
) {
    my ($type, $arg, $files) = @{ $spec };
    remove_tree $multidir->stringify;
    ok $bundle->execute($arg), qq{Execute with $type arg "$arg"};
    file_exists_ok $_ for ($conf_file, @{ $files->{include} });
    file_not_exists_ok $_ for @{ $files->{exclude} };
}

# Make sure we handle --to and --from.
isa_ok $bundle = $CLASS->new(
    sqitch  => $sqitch,
    config  => $sqitch->config,
    from     => 'widgets',
    to       => 'widgets',
    dest_dir => dir '_build',
), $CLASS, 'to/from bundle command';
remove_tree $multidir->stringify;
ok $bundle->execute('pg'), 'Execute to/from bundle!';
file_exists_ok $_ for ($conf_file, @engine[0,3,4]);
file_not_exists_ok $_ for (@engine[1,2,5..$#engine]);
file_contents_is $engine[0],
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=engine' . "\n"
    . "\n"
    . $plan->find('widgets')->as_string . "\n",
    'Plan should have written only "widgets"';

# Make sure we handle to and from args.
isa_ok $bundle = $CLASS->new(
    sqitch  => $sqitch,
    config  => $sqitch->config,
    dest_dir => dir '_build',
), $CLASS, 'another bundle command';
remove_tree $multidir->stringify;
ok $bundle->execute(qw(pg widgets @HEAD)), 'Execute bundle with to/from args!';
file_exists_ok $_ for ($conf_file, @engine[0,3..$#engine]);
file_not_exists_ok $_ for (@engine[1,2]);
file_contents_is $engine[0],
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=engine' . "\n"
    . "\n"
    . $plan->find('widgets')->as_string . "\n"
    . $plan->find('func/add_user')->as_string . "\n",
    'Plan should have written "widgets" and "func/add_user"';

# Should die on unknown argument.
throws_ok { $bundle->execute('nonesuch') } 'App::Sqitch::X',
    'Should get an exception for unknown argument';
is $@->ident, 'bundle', 'Unknown argument error ident shoud be "bundle"';
is $@->message, __x(
    'Unknown argument "{arg}"',
    arg => 'nonesuch',
), 'Unknown argument error message should be correct';

# Should handle multiple arguments, too.
throws_ok { $bundle->execute(qw(ba da dum)) } 'App::Sqitch::X',
    'Should get an exception for unknown arguments';
is $@->ident, 'bundle', 'Unknown arguments error ident shoud be "bundle"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => join ', ', qw(ba da dum)
), 'Unknown arguments error message should be correct';
