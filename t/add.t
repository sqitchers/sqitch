#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 91;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents 0.05;
use File::Path qw(make_path remove_tree);
use Test::NoWarnings 0.083;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::add';

$ENV{SQITCH_USER_DIR} = '.';

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';


my $config = $sqitch->config;

sub dep($$) {
    my $dep = App::Sqitch::Plan::Depend->new(
        %{ App::Sqitch::Plan::Depend->parse( $_[1] ) },
        plan      => $sqitch->plan,
        conflicts => $_[0],
    );
    $dep->project;
    return $dep;
}

isa_ok my $add = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'add',
    config  => $config,
}), $CLASS, 'add command';

can_ok $CLASS, qw(
    options
    requires
    conflicts
    variables
    template_directory
    with_deploy
    with_revert
    with_verify
    deploy_template
    revert_template
    verify_template
    configure
    execute
    _find
    _slurp
    _add
);

is_deeply [$CLASS->options], [qw(
    requires|r=s@
    conflicts|c=s@
    note|n=s@
    set|s=s%
    template-directory=s
    deploy-template=s
    revert-template=s
    verify-template|test-template=s
    deploy!
    revert!
    verify|test!
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
    note      => [],
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    note      => [qw(hellow there)],
}), {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    note      => [qw(hellow there)],
}, 'Should have get requires and conflicts options';

is_deeply $CLASS->configure($config, { template_directory => 't' }), {
    requires  => [],
    conflicts => [],
    note      => [],
    template_directory => Path::Class::dir('t'),
}, 'Should set up template directory option';

throws_ok {
    $CLASS->configure($config, { template_directory => '__nonexistent__' });
} 'App::Sqitch::X', 'Should die if --template-directory does not exist';
is $@->ident, 'add', 'Missing directory ident should be "add"';
is $@->message, __x(
    'Directory "{dir}" does not exist',
    dir => '__nonexistent__',
), 'Missing directory error message should be correct';

throws_ok {
    $CLASS->configure($config, { template_directory => 'README.md' });
} 'App::Sqitch::X', 'Should die if --template-directory does is not a dir';
is $@->ident, 'add', 'In alid directory ident should be "add"';
is $@->message, __x(
    '"{dir}" is not a directory',
    dir => 'README.md',
), 'Invalid directory error message should be correct';

is_deeply $CLASS->configure($config, {
    deploy => 1,
    revert => 1,
    verify => 0,
    deploy_template => 'templates/deploy.tmpl',
    revert_template => 'templates/revert.tmpl',
    verify_template => 'templates/verify.tmpl',
}), {
    requires  => [],
    conflicts => [],
    note      => [],
    with_deploy => 1,
    with_revert => 1,
    with_verify => 0,
    deploy_template => Path::Class::file('templates/deploy.tmpl'),
    revert_template => Path::Class::file('templates/revert.tmpl'),
    verify_template => Path::Class::file('templates/verify.tmpl'),
}, 'Should have get template options';

# Test variable configuration.
CONFIG: {
    local $ENV{SQITCH_CONFIG} = File::Spec->catfile(qw(t add_change.conf));
    my $config = App::Sqitch::Config->new;
    my $dir = dir 't';
    is_deeply $CLASS->configure($config, {}), {
        template_directory => $dir,
        requires  => [],
        conflicts => [],
        note      => [],
    }, 'Variables should by default not be loaded from config';

    is_deeply $CLASS->configure($config, {set => { yo => 'dawg' }}), {
        template_directory => $dir,
        requires  => [],
        conflicts => [],
        note      => [],
        variables => {
            foo => 'bar',
            baz => [qw(hi there you)],
            yo  => 'dawg',
        },
    }, '--set should be merged with config variables';

    is_deeply $CLASS->configure($config, {set => { foo => 'ick' }}), {
        template_directory => $dir,
        requires  => [],
        conflicts => [],
        note      => [],
        variables => {
            foo => 'ick',
            baz => [qw(hi there you)],
        },
    }, '--set should be override config variables';
}

##############################################################################
# Test attributes.
is_deeply $add->requires, [], 'Requires should be an arrayref';
is_deeply $add->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $add->note, [], 'Notes should be an arrayref';
is_deeply $add->variables, {}, 'Varibles should be a hashref';
is $add->template_directory, undef, 'Default dir should be undef';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock(system_dir => Path::Class::dir('nonexistent'));
    for my $script (qw(deploy revert verify)) {
        my $with = "with_$script";
        ok $add->$with, "$with should be true by default";
        my $tmpl = "$script\_template";
        throws_ok { $add->$tmpl } 'App::Sqitch::X', "Should die on $tmpl";
        is $@->ident, 'add', 'Should be an "add" exception';
        is $@->message, __x(
            'Cannot find {script} template',
            script => $script,
        ), "Should get $tmpl failure note";;
    }
}

# Point to a valid template directory.
ok $add = $CLASS->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create add with template_directory';

for my $script (qw(deploy revert verify)) {
    my $tmpl = "$script\_template";
    is $add->$tmpl, Path::Class::file('etc', 'templates', "$script.tmpl"),
        "Should find $script in templates directory";
}

##############################################################################
# Test find().
is $add->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
    '_find should work with template_directory';

ok $add = $CLASS->new(sqitch => $sqitch),
    'Create add with no template directory';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock(system_dir => Path::Class::dir('nonexistent'));
    $config_mock->mock(user_dir => Path::Class::dir('etc'));
    is $add->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with user_dir from Config';

    $config_mock->unmock('user_dir');
    throws_ok { $add->_find('verify') } 'App::Sqitch::X',
        "Should die trying to find template";
    is $@->ident, 'add', 'Should be an "add" exception';
    is $@->message, __x(
        'Cannot find {script} template',
        script => 'verify',
    ), "Should get unfound verify template note";

    $config_mock->mock(system_dir => Path::Class::dir('etc'));
    is $add->_find('deploy'), Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with system_dir from Config';
}

##############################################################################
# Test _slurp().
my $tmpl = Path::Class::file(qw(etc templates deploy.tmpl));
is $ { $add->_slurp($tmpl)}, contents_of $tmpl,
    '_slurp() should load a reference to file contents';

##############################################################################
# Test _add().
make_path 'sql';
my $fn = $sqitch->plan_file;
open my $fh, '>', $fn or die "Cannot open $fn: $!";
say $fh "%project=add\n\n";
close $fh or die "Error closing $fn: $!";
END { remove_tree 'sql' };
my $out = file 'sql', 'sqitch_change_test.sql';
file_not_exists_ok $out;
ok $add->_add('sqitch_change_test', $out, $tmpl),
    'Write out a script';
file_exists_ok $out;
file_contents_is $out, <<EOF, 'The template should have been evaluated';
-- Deploy sqitch_change_test

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF
is_deeply +MockOutput->get_info, [[__x 'Created {file}', file => $out ]],
    'Info should show $out created';

# Try with requires and conflicts.
ok $add =  $CLASS->new(
    sqitch    => $sqitch,
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
), 'Create add cmd with requires and conflicts';

$out = file 'sql', 'another_change_test.sql';
ok $add->_add('another_change_test', $out, $tmpl),
    'Write out a script with requires and conflicts';
is_deeply +MockOutput->get_info, [[__x 'Created {file}', file => $out ]],
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
ok $add = $CLASS->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add with template_directory';

# Override request_note().
my $change_mocker = Test::MockModule->new('App::Sqitch::Plan::Change');
my %request_params;
$change_mocker->mock(request_note => sub {
    shift;
    %request_params = @_;
});

my $deploy_file = file qw(sql deploy widgets_table.sql);
my $revert_file = file qw(sql revert widgets_table.sql);
my $verify_file = file qw(sql verify   widgets_table.sql);

my $plan = $sqitch->plan;
is $plan->get('widgets_table'), undef, 'Should not have "widgets_table" in plan';
dir_not_exists_ok +File::Spec->catdir('sql', $_) for qw(deploy revert verify);
ok $add->execute('widgets_table'), 'Add change "widgets_table"';
isa_ok my $change = $plan->get('widgets_table'), 'App::Sqitch::Plan::Change',
    'Added change';
is $change->name, 'widgets_table', 'Change name should be set';
is_deeply [$change->requires],  [], 'It should have no requires';
is_deeply [$change->conflicts], [], 'It should have no conflicts';
is_deeply \%request_params, {
    for => __ 'add',
    scripts => [$change->deploy_file, $change->revert_file, $change->verify_file],
}, 'It should have prompted for a note';

file_exists_ok $_ for ($deploy_file, $revert_file, $verify_file);
file_contents_like +File::Spec->catfile(qw(sql deploy widgets_table.sql)),
    qr/^-- Deploy widgets_table/, 'Deploy script should look right';
file_contents_like +File::Spec->catfile(qw(sql revert widgets_table.sql)),
    qr/^-- Revert widgets_table/, 'Revert script should look right';
file_contents_like +File::Spec->catfile(qw(sql verify widgets_table.sql)),
    qr/^-- Verify widgets_table/, 'Verify script should look right';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $deploy_file],
    [__x 'Created {file}', file => $revert_file],
    [__x 'Created {file}', file => $verify_file],
    [__x 'Added "{change}" to {file}',
        change => 'widgets_table',
        file   => $sqitch->plan_file,
    ],
], 'Info should have reported file creation';

# Relod the plan file to make sure change is written to it.
$plan->load;
isa_ok $change = $plan->get('widgets_table'), 'App::Sqitch::Plan::Change',
    'Added change in reloaded plan';

# Make sure conflicts are avoided and conflicts and requires are respected.
ok $add = $CLASS->new(
    sqitch             => $sqitch,
    requires           => ['widgets_table'],
    conflicts          => [qw(dr_evil joker)],
    note               => [qw(hello there)],
    with_verify        => 0,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add with template_directory and no verify script';

$deploy_file = file qw(sql deploy foo_table.sql);
$revert_file = file qw(sql revert foo_table.sql);
$verify_file = file qw(sql ferify foo_table.sql);
$deploy_file->touch;

file_exists_ok $deploy_file;
file_not_exists_ok $_ for ($revert_file, $verify_file);
is $plan->get('foo_table'), undef, 'Should not have "foo_table" in plan';
ok $add->execute('foo_table'), 'Add change "foo_table"';
file_exists_ok $_ for ($deploy_file, $revert_file);
file_not_exists_ok $verify_file;
isa_ok $change = $plan->get('foo_table'), 'App::Sqitch::Plan::Change',
    '"foo_table" change';
is_deeply \%request_params, {
    for => __ 'add',
    scripts => [$change->deploy_file, $change->revert_file],
}, 'It should have prompted for a note';

is $change->name, 'foo_table', 'Change name should be set to "foo_table"';
is_deeply [$change->requires],  [dep 0, 'widgets_table'], 'It should have requires';
is_deeply [$change->conflicts], [map { dep 1, $_ } qw(dr_evil joker)], 'It should have conflicts';
is        $change->note, "hello\n\nthere", 'It should have a comment';

is_deeply +MockOutput->get_info, [
    [__x 'Skipped {file}: already exists', file => $deploy_file],
    [__x 'Created {file}', file => $revert_file],
    [__x 'Added "{change}" to {file}',
        change => 'foo_table [widgets_table !dr_evil !joker]',
        file   => $sqitch->plan_file,
    ],
], 'Info should report skipping file and include dependencies';
