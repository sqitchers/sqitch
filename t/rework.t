#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 76;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use URI;
use App::Sqitch::Command::add;
use Path::Class;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents qw(file_contents_identical file_contents_is);
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::rework';

ok my $sqitch = App::Sqitch->new(
    uri     => URI->new('https://github.com/theory/sqitch/'),
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $rework = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'rework',
    config  => $config,
}), $CLASS, 'rework command';

can_ok $CLASS, qw(
    requires
    conflicts
    execute
);

is_deeply [$CLASS->options], [qw(
    requires|r=s@
    conflicts|c=s@
)], 'Options should be set up';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {},
    'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}), {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}, 'Should have get requires and conflicts options';

##############################################################################
# Test attributes.
is_deeply $rework->requires, [], 'Requires should be an arrayref';
is_deeply $rework->conflicts, [], 'Conflicts should be an arrayref';

##############################################################################
# Test execute().
make_path 'sql';
END { remove_tree 'sql' };
my $plan = $sqitch->plan;

throws_ok { $rework->execute('foo') } 'App::Sqitch::X',
    'Should get an example for nonexistent change';
is $@->ident, 'plan', 'Nonexistent change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" does not exist.\n}
    . 'Use "sqitch add {change}" to add it to the plan',
    change => 'foo',
), 'Fail message should say the step does not exist';

# Use the add command to create a step.
my $deploy_file = file qw(sql deploy foo.sql);
my $revert_file = file qw(sql revert foo.sql);
my $test_file   = file qw(sql test   foo.sql);

ok my $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $test_file);
$add->execute('foo');
file_exists_ok($_) for ($deploy_file, $revert_file, $test_file);
ok my $foo = $plan->get('foo'), 'Get the "foo" change';

throws_ok { $rework->execute('foo') } 'App::Sqitch::X',
    'Should get an example for duplicate change';
is $@->ident, 'plan', 'Duplicate change error ident should be "plan"';
is $@->message, __x(
    qq{Cannot rework "{change}" without an intervening tag.\n}
    . 'Use "sqitch tag" to create a tag and try again',
    change => 'foo',
), 'Fail message should say a tag is needed';

# Tag it, and *then* it should work.
ok $plan->tag('@alpha'), 'Tag it';

my $deploy_file2 = file qw(sql deploy foo@alpha.sql);
my $revert_file2 = file qw(sql revert foo@alpha.sql);
my $test_file2   = file qw(sql test   foo@alpha.sql);
MockOutput->get_info;

file_not_exists_ok($_) for ($deploy_file2, $revert_file2, $test_file2);
ok $rework->execute('foo'), 'Rework "foo"';

# The files should have been copied.
file_exists_ok($_) for ($deploy_file, $revert_file, $test_file);
file_exists_ok($_) for ($deploy_file2, $revert_file2, $test_file2);
file_contents_identical($deploy_file2, $deploy_file);
file_contents_identical($test_file2, $test_file);
file_contents_identical($revert_file, $deploy_file);
file_contents_is($revert_file2, <<'EOF', 'New revert should revert');
-- Revert foo

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF

# The plan file should have been updated.
ok $plan->load, 'Reload the plan file';
ok my @steps = $plan->changes, 'Get the steps';
is @steps, 2, 'Should have two steps';
is $steps[0]->name, 'foo', 'First step should be "foo"';
is $steps[1]->name, 'foo', 'Second step should also be "foo"';
is_deeply [$steps[1]->requires], ['foo@alpha'],
    'Reworked step should require the previous step';

is_deeply +MockOutput->get_info, [
    [__x(
        'Added "{change}" to {file}.',
        change => 'foo [:foo@alpha]',
        file   => $sqitch->plan_file,
    )],
    [__n(
        'Modify this file as appropriate:',
        'Modify these files as appropriate:',
        3,
    )],
    ["  * $deploy_file"],
    ["  * $revert_file"],
    ["  * $test_file"],
], 'And the info message should suggest editing the old files';
is_deeply +MockOutput->get_debug, [
    [__x(
        'Copied {src} to {dest}',
        dest => $deploy_file2,
        src  => $deploy_file,
    )],
    [__x(
        'Copied {src} to {dest}',
        dest => $revert_file2,
        src  => $revert_file,
    )],
    [__x(
        'Copied {src} to {dest}',
        dest => $test_file2,
        src  => $test_file,
    )],
    [__x(
        'Copied {src} to {dest}',
        dest => $revert_file,
        src  => $deploy_file,
    )],
], 'Debug should show file copying';

##############################################################################
# Let's do that again. This time with more dependencies and fewer files.
$deploy_file = file qw(sql deploy bar.sql);
$revert_file = file qw(sql revert bar.sql);
$test_file   = file qw(sql test   bar.sql);
ok $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates)),
    with_revert => 0,
    with_test   => 0,
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $test_file);
$add->execute('bar');
file_exists_ok($deploy_file);
file_not_exists_ok($_) for ($revert_file, $test_file);
ok $plan->tag('@beta'), 'Tag it with @beta';

my $deploy_file3 = file qw(sql deploy bar@beta.sql);
my $revert_file3 = file qw(sql revert bar@beta.sql);
my $test_file3   = file qw(sql test   bar@beta.sql);
MockOutput->get_info;

isa_ok $rework = App::Sqitch::Command::rework->new(
    sqitch    => $sqitch,
    command   => 'rework',
    config    => $config,
    requires  => ['foo'],
    conflicts => ['dr_evil'],
), $CLASS, 'rework command with requirements and conflicts';

# Check the files.
file_not_exists_ok($_) for ($deploy_file3, $revert_file3, $test_file3);
ok $rework->execute('bar'), 'Rework "bar"';
file_exists_ok($deploy_file);
file_not_exists_ok($_) for ($revert_file, $test_file);
file_exists_ok($deploy_file3);
file_not_exists_ok($_) for ($revert_file3, $test_file3);

# The plan file should have been updated.
ok $plan->load, 'Reload the plan file again';
ok @steps = $plan->changes, 'Get the steps';
is @steps, 4, 'Should have four steps';
is $steps[0]->name, 'foo', 'First step should be "foo"';
is $steps[1]->name, 'foo', 'Second step should also be "foo"';
is $steps[2]->name, 'bar', 'First step should be "bar"';
is $steps[3]->name, 'bar', 'Second step should also be "bar"';
is_deeply [$steps[3]->requires], ['bar@beta', 'foo'],
    'Requires should have been passed to reworked change';
is_deeply [$steps[3]->conflicts], ['dr_evil'],
    'Conflicts should have been passed to reworked change';

is_deeply +MockOutput->get_info, [
    [__x(
        'Added "{change}" to {file}.',
        change => 'bar [:bar@beta :foo !dr_evil]',
        file   => $sqitch->plan_file,
    )],
    [__n(
        'Modify this file as appropriate:',
        'Modify these files as appropriate:',
        1,
    )],
    ["  * $deploy_file"],
], 'And the info message should show only the one file to modify';

is_deeply +MockOutput->get_debug, [
    [__x(
        'Copied {src} to {dest}',
        dest => $deploy_file3,
        src  => $deploy_file,
    )],
    [__x(
        'Skipped {dest}: {src} does not exist',
        dest => $revert_file3,
        src  => $revert_file,
    )],
    [__x(
        'Skipped {dest}: {src} does not exist',
        dest => $test_file3,
        src  => $test_file,
    )],
    [__x(
        'Skipped {dest}: {src} does not exist',
        dest => $revert_file,
        src  => $revert_file3, # No previous revert, no need for new revert.
    )],
], 'Should have debug oputput for missing files';
