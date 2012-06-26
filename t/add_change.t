#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 76;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::NoWarnings;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents;
use File::Path qw(make_path remove_tree);
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::add_change';

ok my $sqitch = App::Sqitch->new(
    uri     => URI->new('https://github.com/theory/sqitch/'),
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $add_change = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'add-change',
    config  => $config,
}), $CLASS, 'add_change command';

can_ok $CLASS, qw(
    options
    requires
    conflicts
    variables
    template_directory
    with_deploy
    with_revert
    with_test
    deploy_template
    revert_template
    test_template
    configure
    execute
    _find
    _slurp
    _add
);

is_deeply [$CLASS->options], [qw(
    requires|r=s@
    conflicts|c=s@
    set|s=s%
    template-directory=s
    deploy-template=s
    revert-template=s
    test-template=s
    deploy!
    revert!
    test!
)], 'Options should be set up';

sub contents_of ($) {
    my $file = shift;
    open my $fh, "<:encoding(UTF-8)", $file or die "cannot open $file: $!";
    local $/;
    return <$fh>;
}

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {
    requires  => [],
    conflicts => [],
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}), {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}, 'Should have get requires and conflicts options';

is_deeply $CLASS->configure($config, { template_directory => 't' }), {
    requires  => [],
    conflicts => [],
    template_directory => Path::Class::dir('t'),
}, 'Should set up template directory option';

is_deeply $CLASS->configure($config, {
    deploy => 1,
    revert => 1,
    test   => 0,
    deploy_template => 'templates/deploy.tmpl',
    revert_template => 'templates/revert.tmpl',
    test_template => 'templates/test.tmpl',
}), {
    requires  => [],
    conflicts => [],
    with_deploy => 1,
    with_revert => 1,
    with_test => 0,
    deploy_template => Path::Class::file('templates/deploy.tmpl'),
    revert_template => Path::Class::file('templates/revert.tmpl'),
    test_template => Path::Class::file('templates/test.tmpl'),
}, 'Should have get template options';

# Test variable configuration.
CONFIG: {
    local $ENV{SQITCH_CONFIG} = File::Spec->catfile(qw(t add_change.conf));
    my $config = App::Sqitch::Config->new;
    is_deeply $CLASS->configure($config, {}), {
        requires  => [],
        conflicts => [],
    }, 'Variables should by default not be loaded from config';

    is_deeply $CLASS->configure($config, {set => { yo => 'dawg' }}), {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'bar',
            baz => [qw(hi there you)],
            yo  => 'dawg',
        },
    }, '--set should be merged with config variables';

    is_deeply $CLASS->configure($config, {set => { foo => 'ick' }}), {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'ick',
            baz => [qw(hi there you)],
        },
    }, '--set should be override config variables';
}

##############################################################################
# Test attributes.
is_deeply $add_change->requires, [], 'Requires should be an arrayref';
is_deeply $add_change->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $add_change->variables, {}, 'Varibles should be a hashref';
is $add_change->template_directory, undef, 'Default dir should be undef';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock(system_dir => Path::Class::dir('nonexistent'));
    for my $script (qw(deploy revert test)) {
        my $with = "with_$script";
        ok $add_change->$with, "$with should be true by default";
        my $tmpl = "$script\_template";
        throws_ok { $add_change->$tmpl } qr/FAIL/, "Should die on $tmpl";
        is_deeply +MockOutput->get_fail, [["Cannot find $script template"]],
            "Should get $tmpl failure message";
    }
}

# Point to a valid template directory.
ok $add_change = $CLASS->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create add_change with template_directory';

for my $script (qw(deploy revert test)) {
    my $tmpl = "$script\_template";
    is $add_change->$tmpl, Path::Class::file('etc', 'templates', "$script.tmpl"),
        "Should find $script in templates directory";
}

##############################################################################
# Test find().
is $add_change->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
    '_find should work with template_directory';

ok $add_change = $CLASS->new(sqitch => $sqitch),
    'Create add_change with no template directory';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock(system_dir => Path::Class::dir('nonexistent'));
    $config_mock->mock(user_dir => Path::Class::dir('etc'));
    is $add_change->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with user_dir from Config';

    $config_mock->unmock('user_dir');
    throws_ok { $add_change->_find('test') } qr/FAIL/,
        "Should die trying to find template";
    is_deeply +MockOutput->get_fail, [["Cannot find test template"]],
        "Should get unfound test template message";

    $config_mock->mock(system_dir => Path::Class::dir('etc'));
    is $add_change->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with system_dir from Config';
}

##############################################################################
# Test _slurp().
my $tmpl = Path::Class::file(qw(etc templates deploy.tmpl));
is $ { $add_change->_slurp($tmpl)}, contents_of $tmpl,
    '_slurp() should load a reference to file contents';

##############################################################################
# Test _add().
make_path 'sql';
END { remove_tree 'sql' };
my $out = file 'sql', 'sqitch_change_test.sql';
file_not_exists_ok $out;
ok $add_change->_add('sqitch_change_test', $out, $tmpl),
    'Write out a script';
file_exists_ok $out;
file_contents_is $out, <<EOF, 'The template should have been evaluated';
-- Deploy sqitch_change_test

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF
is_deeply +MockOutput->get_info, [["Created $out"]],
    'Info should show $out created';

# Try with requires and conflicts.
ok $add_change =  $CLASS->new(
    sqitch    => $sqitch,
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
), 'Create add_change cmd with requires and conflicts';

$out = file 'sql', 'another_change_test.sql';
ok $add_change->_add('another_change_test', $out, $tmpl),
    'Write out a script with requires and conflicts';
is_deeply +MockOutput->get_info, [["Created $out"]],
    'Info should show $out created';
file_contents_is $out, <<EOF, 'The template should have been evaluated with requires and conflicts';
-- Deploy another_change_test
-- requires: foo
-- requires: bar
-- conflicts: baz

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF
unlink $out;

##############################################################################
# Test execute.
ok $add_change = $CLASS->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add_change with template_directory';

my $deploy_file = file qw(sql deploy widgets_table.sql);
my $revert_file = file qw(sql revert widgets_table.sql);
my $test_file   = file qw(sql test   widgets_table.sql);

my $plan = $sqitch->plan;
is $plan->get('widgets_table'), undef, 'Should not have "widgets_table" in plan';
dir_not_exists_ok +File::Spec->catdir('sql', $_) for qw(deploy revert test);
ok $add_change->execute('widgets_table'), 'Add change "widgets_table"';
isa_ok my $change = $plan->get('widgets_table'), 'App::Sqitch::Plan::Change',
    'Added change';
is $change->name, 'widgets_table', 'Change name should be set';
is_deeply [$change->requires],  [], 'It should have no requires';
is_deeply [$change->conflicts], [], 'It should have no conflicts';

file_exists_ok $_ for ($deploy_file, $revert_file, $test_file);
file_contents_like +File::Spec->catfile(qw(sql deploy widgets_table.sql)),
    qr/^-- Deploy widgets_table/, 'Deploy script should look right';
file_contents_like +File::Spec->catfile(qw(sql revert widgets_table.sql)),
    qr/^-- Revert widgets_table/, 'Revert script should look right';
file_contents_like +File::Spec->catfile(qw(sql test widgets_table.sql)),
    qr/^-- Test widgets_table/, 'Test script should look right';
is_deeply +MockOutput->get_info, [
    ["Created $deploy_file"],
    ["Created $revert_file"],
    ["Created $test_file"],
], 'Info should have reported file creation';

# Make sure conflicts are avoided and conflicts and requires are respected.
ok $add_change = $CLASS->new(
    sqitch => $sqitch,
    requires  => ['widgets_table'],
    conflicts => [qw(dr_evil joker)],
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add_change with template_directory';

$deploy_file = file qw(sql deploy foo_table.sql);
$revert_file = file qw(sql revert foo_table.sql);
$test_file   = file qw(sql test   foo_table.sql);
$deploy_file->touch;

file_exists_ok $deploy_file;
file_not_exists_ok $_ for ($revert_file, $test_file);
is $plan->get('foo_table'), undef, 'Should not have "foo_table" in plan';
ok $add_change->execute('foo_table'), 'Add change "foo_table"';
file_exists_ok $_ for ($deploy_file, $revert_file, $test_file);
isa_ok $change = $plan->get('foo_table'), 'App::Sqitch::Plan::Change',
    '"foo_table" change';

is $change->name, 'foo_table', 'Change name should be set to "foo_table"';
is_deeply [$change->requires],  ['widgets_table'], 'It should have requires';
is_deeply [$change->conflicts], [qw(dr_evil joker)], 'It should have conflicts';

is_deeply +MockOutput->get_info, [
    ["Skipped $deploy_file: already exists"],
    ["Created $revert_file"],
    ["Created $test_file"],
], 'Info should have reported skipping file';
