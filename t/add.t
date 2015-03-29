#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 224;
#use Test::More 'no_plan';
use App::Sqitch;
use App::Sqitch::Target;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Exception;
use Test::Dir;
use File::Temp 'tempdir';
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents 0.05;
use File::Path qw(make_path remove_tree);
use Test::NoWarnings 0.083;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::add';

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $config_mock = Test::MockModule->new('App::Sqitch::Config');
my $sysdir = dir 'nonexistent';
my $usrdir = dir 'nonexistent';
$config_mock->mock(system_dir => sub { $sysdir });
$config_mock->mock(user_dir   => sub { $usrdir });

ok my $sqitch = App::Sqitch->new(
    options => {
        top_dir => dir('test-add')->stringify,
        engine => 'pg',
    }
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;

isa_ok my $add = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'add',
    config  => $config,
}), $CLASS, 'add command';
my $target = $add->default_target;

sub dep($$) {
    my $dep = App::Sqitch::Plan::Depend->new(
        %{ App::Sqitch::Plan::Depend->parse( $_[1] ) },
        plan      => $add->default_target->plan,
        conflicts => $_[0],
    );
    $dep->project;
    return $dep;
}

can_ok $CLASS, qw(
    options
    requires
    conflicts
    variables
    template_name
    template_directory
    with_scripts
    templates
    open_editor
    configure
    execute
    _config_templates
    all_templates
    _slurp
    _add
);

is_deeply [$CLASS->options], [qw(
    change-name|change|c=s
    requires|r=s@
    conflicts|x=s@
    note|n|m=s@
    all|a!
    template-name|template|t=s
    template-directory=s
    with=s@
    without=s@
    use=s%
    open-editor|edit|e!

    deploy-template=s
    revert-template=s
    verify-template=s
    deploy!
    revert!
    verify!
)], 'Options should be set up';

sub contents_of ($) {
    my $file = shift;
    open my $fh, "<:utf8_strict", $file or die "cannot open $file: $!";
    local $/;
    return <$fh>;
}

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}, $sqitch), {
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
    template_directory => dir('t'),
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

is_deeply $CLASS->configure($config, { template_name => 'foo' }), {
    requires  => [],
    conflicts => [],
    note      => [],
    template_name => 'foo',
}, 'Should set up template name option';

is_deeply $CLASS->configure($config, {
    all          => 1,
    with_scripts => { deploy => 1, revert => 1, verify => 0 },
    use          => {
        deploy => 'etc/templates/deploy/pg.tmpl',
        revert => 'etc/templates/revert/pg.tmpl',
        verify => 'etc/templates/verify/pg.tmpl',
        whatev => 'etc/templates/verify/pg.tmpl',
    },
}), {
    all       => 1,
    requires  => [],
    conflicts => [],
    note      => [],
    with_scripts => { deploy => 1, revert => 1, verify => 0 },
    templates => {
        deploy => file('etc/templates/deploy/pg.tmpl'),
        revert => file('etc/templates/revert/pg.tmpl'),
        verify => file('etc/templates/verify/pg.tmpl'),
        whatev => file('etc/templates/verify/pg.tmpl'),
    }
}, 'Should have get template options';

# Test variable configuration.
CONFIG: {
    local $ENV{SQITCH_CONFIG} = File::Spec->catfile(qw(t add_change.conf));
    my $config = App::Sqitch::Config->new;
    my $dir = dir 't';
    is_deeply $CLASS->configure($config, {}), {
        template_directory => $dir,
        template_name      => 'hi',
        requires  => [],
        conflicts => [],
        note      => [],
    }, 'Variables should by default not be loaded from config';

    is_deeply $CLASS->configure($config, {set => { yo => 'dawg' }}), {
        template_directory => $dir,
        template_name      => 'hi',
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
        template_name      => 'hi',
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
is $add->template_name, undef, 'Default temlate_name should be undef';
is_deeply $add->with_scripts, {}, 'Default with_scripts should be empty';
is_deeply $add->templates, {}, 'Default templates should be empty';

##############################################################################
# Test _check_script.
isa_ok my $check = $CLASS->can('_check_script'), 'CODE', '_check_script';
my $tmpl = 'etc/templates/verify/pg.tmpl';
is $check->($tmpl), file($tmpl), '_check_script should be okay with script';

throws_ok { $check->('nonexistent') } 'App::Sqitch::X',
    '_check_script should die on nonexistent file';
is $@->ident, 'add', 'Nonexistent file ident should be "add"';
is $@->message, __x(
    'Template {template} does not exist',
    template => 'nonexistent',
), 'Nonexistent file error message should be correct';

throws_ok { $check->('lib') } 'App::Sqitch::X',
    '_check_script should die on directory';
is $@->ident, 'add', 'Directory error ident should be "add"';
is $@->message, __x(
    'Template {template} is not a file',
    template => 'lib',
), 'Directory error message should be correct';

##############################################################################
# Test _config_templates.
READCONFIG: {
    local $ENV{SQITCH_CONFIG} = file('t/templates.conf')->stringify;
    ok my $sqitch = App::Sqitch->new(
        options => { top_dir => dir('test-add')->stringify },
    ), 'Load another sqitch sqitch object';
    my $config = $sqitch->config;
    ok $add = $CLASS->new(sqitch => $sqitch),
        'Create add with template config';
    is_deeply $add->_config_templates($config), {
        deploy => file('etc/templates/deploy/pg.tmpl'),
        revert => file('etc/templates/revert/pg.tmpl'),
        test   => file('etc/templates/verify/pg.tmpl'),
        verify => file('etc/templates/verify/pg.tmpl'),
    }, 'Should load the config templates';
}

##############################################################################
# Test all_templates().
my $tmpldir = dir 'etc/templates';

# First, specify template directory.
ok $add = $CLASS->new(sqitch => $sqitch, template_directory => $tmpldir),
    'Add object with template directory';
is $add->template_name, undef, 'Template name should be undef';
my $tname = $add->template_name || $target->engine_key;
is_deeply $add->all_templates($tname), {
    deploy => file('etc/templates/deploy/pg.tmpl'),
    revert => file('etc/templates/revert/pg.tmpl'),
    verify => file('etc/templates/verify/pg.tmpl'),
}, 'Should find all templates in directory';

# Now let it find the templates in the user dir.
$usrdir = dir 'etc';
ok $add = $CLASS->new(sqitch => $sqitch, template_name => 'sqlite'),
    'Add object with template name';
is_deeply $add->all_templates($add->template_name), {
    deploy => file('etc/templates/deploy/sqlite.tmpl'),
    revert => file('etc/templates/revert/sqlite.tmpl'),
    verify => file('etc/templates/verify/sqlite.tmpl'),
}, 'Should find all templates in user directory';

# And then the system dir.
($usrdir, $sysdir) = ($sysdir, $usrdir);
ok $add = $CLASS->new(sqitch => $sqitch, template_name => 'mysql'),
    'Add object with another template name';
is_deeply $add->all_templates($add->template_name), {
    deploy => file('etc/templates/deploy/mysql.tmpl'),
    revert => file('etc/templates/revert/mysql.tmpl'),
    verify => file('etc/templates/verify/mysql.tmpl'),
}, 'Should find all templates in systsem directory';

# Now make sure it combines directories.
my $tmp_dir = dir tempdir CLEANUP => 1;
for my $script (qw(deploy whatev)) {
    my $subdir = $tmp_dir->subdir($script);
    $subdir->mkpath;
    $subdir->file('pg.tmpl')->touch;
}

ok $add = $CLASS->new(sqitch => $sqitch, template_directory => $tmp_dir),
    'Add object with temporary template directory';
is_deeply $add->all_templates($tname), {
    deploy => $tmp_dir->file('deploy/pg.tmpl'),
    whatev => $tmp_dir->file('whatev/pg.tmpl'),
    revert => file('etc/templates/revert/pg.tmpl'),
    verify => file('etc/templates/verify/pg.tmpl'),
}, 'Template dir files should override others';

# Add in configured files.
ok $add = $CLASS->new(
    sqitch => $sqitch,
    template_directory => $tmp_dir,
    templates => {
        foo => file('foo'),
        verify => file('verify'),
        deploy => file('deploy'),
    },
), 'Add object with configured templates';

is_deeply $add->all_templates($tname), {
    deploy => file('deploy'),
    verify => file('verify'),
    foo => file('foo'),
    whatev => $tmp_dir->file('whatev/pg.tmpl'),
    revert => file('etc/templates/revert/pg.tmpl'),
}, 'Template dir files should override others';

# Should die when missing files.
$sysdir = $usrdir;
for my $script (qw(deploy revert verify)) {
    ok $add = $CLASS->new(
        sqitch => $sqitch,
        with_scripts => { deploy => 0, revert => 0, verify => 0, $script => 1 },
    ), "Add object requiring $script template";

    throws_ok { $add->all_templates($tname) } 'App::Sqitch::X',
        "Should get error for missing $script template";
    is $@->ident, 'add', qq{Missing $script template ident should be "add"};
    is $@->message, __x(
        'Cannot find {script} template',
        script => $script,
    ), "Missing $script template message should be correct";
}

##############################################################################
# Test _slurp().
$tmpl = file(qw(etc templates deploy pg.tmpl));
is $ { $add->_slurp($tmpl)}, contents_of $tmpl,
    '_slurp() should load a reference to file contents';

##############################################################################
# Test _add().

my $test_add = sub {
    my $engine = shift;
    make_path 'test-add';
    my $fn = $target->plan_file;
    open my $fh, '>', $fn or die "Cannot open $fn: $!";
    say $fh "%project=add\n\n";
    close $fh or die "Error closing $fn: $!";
    END { remove_tree 'test-add' };
    my $out = file 'test-add', 'sqitch_change_test.sql';
    file_not_exists_ok $out;
    ok my $add = $CLASS->new(sqitch => $sqitch), 'Create add command';
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
    unlink $out;

    # Try with requires and conflicts.
    ok $add =  $CLASS->new(
        sqitch    => $sqitch,
        requires  => [qw(foo bar)],
        conflicts => ['baz'],
    ), 'Create add cmd with requires and conflicts';

    $out = file 'test-add', 'another_change_test.sql';
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
};

# First, test  with Template::Tiny.
unshift @INC => sub {
    my ($self, $file) = @_;
    return if $file ne 'Template.pm';
    my $i = 0;
    return sub {
        $_ = 'die "NO ONE HERE";';
        return $i = !$i;
    }, 1;
};

$test_add->('Template::Tiny');

# Test _add() with Template.
shift @INC;
delete $INC{'Template.pm'};
SKIP: {
    skip 'Template Toolkit not installed', 14 unless eval 'use Template; 1';
    $test_add->('Template Toolkit');

    # Template Toolkit should throw an error on template syntax errors.
    ok my $add = $CLASS->new(sqitch => $sqitch), 'Create add command';
    my $mock_add = Test::MockModule->new($CLASS);
    $mock_add->mock(_slurp => sub { \'[% IF foo %]' });
    my $out = file 'test-add', 'sqitch_change_test.sql';

    throws_ok { $add->_add('sqitch_change_test', $out, $tmpl) }
        'App::Sqitch::X', 'Should get an exception on TT syntax error';
    is $@->ident, 'add', 'TT exception ident should be "add"';
    is $@->message, __x(
        'Error executing {template}: {error}',
        template => $tmpl,
        error    => 'file error - parse error - input text line 1: unexpected end of input',
    ), 'TT exception message should include the original error message';
}

##############################################################################
# Test execute.
ok $add = $CLASS->new(
    sqitch => $sqitch,
    template_directory => dir(qw(etc templates))
), 'Create another add with template_directory';

# Override request_note().
my $change_mocker = Test::MockModule->new('App::Sqitch::Plan::Change');
my %request_params;
$change_mocker->mock(request_note => sub {
    my $self = shift;
    %request_params = @_;
    return $self->note;
});

my $deploy_file = file qw(test-add deploy widgets_table.sql);
my $revert_file = file qw(test-add revert widgets_table.sql);
my $verify_file = file qw(test-add verify widgets_table.sql);

my $plan = $add->default_target->plan;
is $plan->get('widgets_table'), undef, 'Should not have "widgets_table" in plan';
dir_not_exists_ok +File::Spec->catdir('test-add', $_) for qw(deploy revert verify);
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
file_contents_like $deploy_file, qr/^-- Deploy widgets_table/,
    'Deploy script should look right';
file_contents_like $revert_file, qr/^-- Revert widgets_table/,
    'Revert script should look right';
file_contents_like $verify_file, qr/^-- Verify widgets_table/,
    'Verify script should look right';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $deploy_file],
    [__x 'Created {file}', file => $revert_file],
    [__x 'Created {file}', file => $verify_file],
    [__x 'Added "{change}" to {file}',
        change => 'widgets_table',
        file   => $target->plan_file,
    ],
], 'Info should have reported file creation';

# Relod the plan file to make sure change is written to it.
$plan->load;
isa_ok $change = $plan->get('widgets_table'), 'App::Sqitch::Plan::Change',
    'Added change in reloaded plan';

# Make sure conflicts are avoided and conflicts and requires are respected.
ok $add = $CLASS->new(
    change_name        => 'foo_table',
    sqitch             => $sqitch,
    requires           => ['widgets_table'],
    conflicts          => [qw(dr_evil joker)],
    note               => [qw(hello there)],
    with_scripts       => { verify => 0 },
    template_directory => dir(qw(etc templates))
), 'Create another add with template_directory and no verify script';

$deploy_file = file qw(test-add deploy foo_table.sql);
$revert_file = file qw(test-add revert foo_table.sql);
$verify_file = file qw(test-add ferify foo_table.sql);
$deploy_file->touch;

file_exists_ok $deploy_file;
file_not_exists_ok $_ for ($revert_file, $verify_file);
is $plan->get('foo_table'), undef, 'Should not have "foo_table" in plan';
ok $add->execute, 'Add change "foo_table"';
file_exists_ok $_ for ($deploy_file, $revert_file);
file_not_exists_ok $verify_file;
$plan = $add->default_target->plan;
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
        file   => $target->plan_file,
    ],
], 'Info should report skipping file and include dependencies';

# Make sure we die on an unknown argument.
throws_ok { $add->execute(qw(foo bar)) } 'App::Sqitch::X',
    'Should get an error on unkonwn argument';
is $@->ident, 'add', 'Unkown argument error ident should be "add"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => 'foo, bar',
), 'Unknown argument error message should be correct';

# Make sure --open-editor works
MOCKSHELL: {
    my $sqitch_mocker = Test::MockModule->new('App::Sqitch');
    my $shell_cmd;
    $sqitch_mocker->mock(shell =>       sub { $shell_cmd = $_[1] });
    $sqitch_mocker->mock(quote_shell => sub { shift; join ' ' => @_ });

    ok $add = $CLASS->new(
        sqitch              => $sqitch,
        template_directory  => dir(qw(etc templates)),
        note                => ['Testing --open-editor'],
        open_editor         => 1,
    ), 'Create another add with open_editor';

    my $deploy_file = file qw(test-add deploy open_editor.sql);
    my $revert_file = file qw(test-add revert open_editor.sql);
    my $verify_file = file qw(test-add verify open_editor.sql);

    my $plan = $add->default_target->plan;
    is $plan->get('open_editor'), undef, 'Should not have "open_editor" in plan';
    ok $add->execute('open_editor'), 'Add change "open_editor"';
    isa_ok my $change = $plan->get('open_editor'), 'App::Sqitch::Plan::Change',
        'Added change';
    is $change->name, 'open_editor', 'Change name should be set';
    is $shell_cmd, join(' ', $sqitch->editor, $deploy_file, $revert_file, $verify_file),
        'It should have prompted to edit sql files';

    file_exists_ok $_ for ($deploy_file, $revert_file, $verify_file);
    file_contents_like +File::Spec->catfile(qw(test-add deploy open_editor.sql)),
        qr/^-- Deploy open_editor/, 'Deploy script should look right';
    file_contents_like +File::Spec->catfile(qw(test-add revert open_editor.sql)),
        qr/^-- Revert open_editor/, 'Revert script should look right';
    file_contents_like +File::Spec->catfile(qw(test-add verify open_editor.sql)),
        qr/^-- Verify open_editor/, 'Verify script should look right';
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $deploy_file],
        [__x 'Created {file}', file => $revert_file],
        [__x 'Created {file}', file => $verify_file],
        [__x 'Added "{change}" to {file}',
            change => 'open_editor',
            file   => $target->plan_file,
        ],
    ], 'Info should have reported file creation';
};

# Make sure an additional script and an exclusion work properly.
EXTRAS: {
    ok my $add = $CLASS->new(
        sqitch              => $sqitch,
        template_directory  => dir(qw(etc templates)),
        with_scripts        => { verify => 0 },
        templates           => { whatev => file(qw(etc templates verify mysql.tmpl)) },
        note                => ['Testing custom scripts'],
    ), 'Create another add with custom script and no verify';

    my $deploy_file = file qw(test-add deploy custom_script.sql);
    my $revert_file = file qw(test-add revert custom_script.sql);
    my $verify_file = file qw(test-add verify custom_script.sql);
    my $whatev_file = file qw(test-add whatev custom_script.sql);

    ok $add->execute('custom_script'), 'Add change "custom_script"';
    my $plan = $add->default_target->plan;
    isa_ok my $change = $plan->get('custom_script'), 'App::Sqitch::Plan::Change',
        'Added change';
    is $change->name, 'custom_script', 'Change name should be set';
    is_deeply [$change->requires],  [], 'It should have no requires';
    is_deeply [$change->conflicts], [], 'It should have no conflicts';
    is_deeply \%request_params, {
        for => __ 'add',
        scripts => [ map { $change->script_file($_) } qw(deploy revert whatev)]
    }, 'It should have prompted for a note';

    file_exists_ok $_ for ($deploy_file, $revert_file, $whatev_file);
    file_not_exists_ok $verify_file;
    file_contents_like $deploy_file, qr/^-- Deploy custom_script/,
        'Deploy script should look right';
    file_contents_like $revert_file, qr/^-- Revert custom_script/,
        'Revert script should look right';
    file_contents_like $whatev_file, qr/^-- Verify custom_script/,
        'Whatev script should look right';
    file_contents_unlike $whatev_file, qr/^BEGIN/,
        'Whatev script should be based on the MySQL verify script';
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $deploy_file],
        [__x 'Created {file}', file => $revert_file],
        [__x 'Created {file}', file => $whatev_file],
        [__x 'Added "{change}" to {file}',
           change => 'custom_script',
           file   => $target->plan_file,
        ],
    ], 'Info should have reported file creation';

    # Relod the plan file to make sure change is written to it.
    $plan->load;
    isa_ok $change = $plan->get('custom_script'), 'App::Sqitch::Plan::Change',
        'Added change in reloaded plan';
}

# Make sure a configuration with multiple plans works.
MULTIPLAN: {
    make_path 'test-multiadd';
    END { remove_tree 'test-multiadd' };
    chdir 'test-multiadd';
    my $conf = file 'multiadd.conf';
    $conf->spew(join "\n",
        '[core]',
        'engine = pg',
        '[engine "pg"]',
        'top_dir = pg',
        '[engine "sqlite"]',
        'top_dir = sqlite',
        '[engine "mysql"]',
        'top_dir = mysql',
    );

    # Create plan files and determine the scripts that to be created.
    my @scripts = map {
        my $dir = dir $_;
        $dir->mkpath;
        $dir->file('sqitch.plan')->spew("%project=add\n\n");
        map { $dir->file($_, 'widgets.sql') } qw(deploy revert verify);
    } qw(pg sqlite mysql);

    # Load up the configuration for this project.
    local $ENV{SQITCH_CONFIG} = $conf;
    my $sqitch = App::Sqitch->new;
    ok my $add = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another add with custom multiplan config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 3, 'Should have three targets';

    # Make sure the target list matches our script list order (by engine).
    # pg always comes first, as primary engine, but the other two are random.
    push @targets, splice @targets, 1, 1 if $targets[1]->engine_key ne 'sqlite';

    # Let's do this thing!
    ok $add->execute('widgets'), 'Add change "widgets" to all plans';
    ok $_->plan->get('widgets'), 'Should have "widgets" in ' . $_->engine_key . ' plan'
         for @targets;
    file_exists_ok $_ for @scripts;

    # Make sure we see the proper output.
    my $info = MockOutput->get_info;
    my $ekey = $targets[1]->engine_key;
    if ($info->[4][0] !~ /$ekey/) {
        # Got the targets in a different order. So reorder results to match.
        push @{ $info } => splice @{ $info }, 4, 4;
    }
    is_deeply $info, [
        (map { [__x 'Created {file}', file => $_] } @scripts[0..2]),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[0]->plan_file,
        ],
        (map { [__x 'Created {file}', file => $_] } @scripts[3..5]),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[1]->plan_file,
        ],
        (map { [__x 'Created {file}', file => $_] } @scripts[6..8]),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[2]->plan_file,
        ],
    ], 'Info should have reported all script creations and plan updates';

    # Make sure we get an error using --all and a target arg.
    throws_ok { $add->execute('foo', 'pg' ) } 'App::Sqitch::X',
        'Should get an error for --all and a target arg';
    is $@->ident, 'add', 'Mixed arguments error ident should be "add"';
    is $@->message, __(
        'Cannot specify both --all and engine, target, or plan arugments'
    ), 'Mixed arguments error message should be correct';

    # Now try adding a change to just one engine. Remove --all
    ok $add = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create yet another add with custom multiplan config';

    ok $add->execute('choc', 'sqlite'), 'Add change "choc" to the sqlite plan';
    my %targets = map { $_->engine_key => $_ }
        App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is keys %targets, 3, 'Should still have three targets';
    ok !$targets{pg}->plan->get('choc'), 'Should not have "choc" in the pg plan';
    ok !$targets{mysql}->plan->get('choc'), 'Should not have "choc" in the mysql plan';
    ok $targets{sqlite}->plan->get('choc'), 'Should have "choc" in the sqlite plan';

    @scripts = map {
        my $dir = dir $_;
        $dir->mkpath;
        map { $dir->file($_, 'choc.sql') } qw(deploy revert verify);
    } qw(sqlite pg mysql);
    file_exists_ok $_ for @scripts[0..2];
    file_not_exists_ok $_ for @scripts[3..8];
    is_deeply +MockOutput->get_info, [
        (map { [__x 'Created {file}', file => $_] } @scripts[0..2]),
        [
            __x 'Added "{change}" to {file}',
            change => 'choc',
            file   => $targets{sqlite}->plan_file,
        ],
    ], 'Info should have reported sqlite choc script creations and plan updates';

    chdir File::Spec->updir;
}

# Make sure we update only one plan but write out multiple target files.
MULTITARGET: {
    remove_tree 'test-multiadd';
    make_path 'test-multiadd';
    chdir 'test-multiadd';
    my $conf = file 'multiadd.conf';
    $conf->spew(join "\n",
        '[core]',
        'engine = pg',
        'plan_file = sqitch.plan',
        '[engine "pg"]',
        'top_dir = pg',
        '[engine "sqlite"]',
        'top_dir = sqlite',
        '[add]',
        'all = true',
    );
    file('sqitch.plan')->spew("%project=add\n\n");

    # Create list of scripts to be created.
    my @scripts = map {
        my $dir = dir $_;
        $dir->mkpath;
        map { $dir->file($_, 'widgets.sql') } qw(deploy revert verify);
    } qw(pg sqlite);

    # Load up the configuration for this project.
    local $ENV{SQITCH_CONFIG} = $conf;
    my $sqitch = App::Sqitch->new;
    ok my $add = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple targets'],
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another add with single plan, multi-target config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 2, 'Should have two targets';
    is $targets[0]->plan_file, $targets[1]->plan_file,
        'Targets should use the same plan file';

    # Let's do this thing!
    ok $add->execute('widgets'), 'Add change "widgets" to all plans';
    ok $targets[0]->plan->get('widgets'), 'Should have "widgets" in the plan';
    file_exists_ok $_ for @scripts;

    is_deeply +MockOutput->get_info, [
        (map { [__x 'Created {file}', file => $_] } @scripts),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[0]->plan_file,
        ],
    ], 'Info should have reported all script creations and one plan update';
    chdir File::Spec->updir;
}

# Make sure we're okay with multiple plans sharing the same top dir.
ONETOP: {
    remove_tree 'test-multiadd';
    make_path 'test-multiadd';
    chdir 'test-multiadd';
    my $conf = file 'multiadd.conf';
    $conf->spew(join "\n",
        '[core]',
        'engine = pg',
        '[engine "pg"]',
        'plan_file = pg.plan',
        '[engine "sqlite"]',
        'plan_file = sqlite.plan',
    );
    file("$_.plan")->spew("%project=add\n\n") for qw(pg sqlite);

    # Create list of scripts to be created.
    my @scripts = map { file $_, 'widgets.sql' } qw(deploy revert verify);

    # Load up the configuration for this project.
    local $ENV{SQITCH_CONFIG} = $conf;
    my $sqitch = App::Sqitch->new;
    ok my $add = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing two targets, one top_dir'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another add with two targets, one top dir';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 2, 'Should have two targets';
    is $targets[0]->plan_file, file('pg.plan'),
        'First target plan should be in pg.plan';
    is $targets[1]->plan_file, file('sqlite.plan'),
        'Second target plan should be in sqlite.plan';

    # Let's do this thing!
    ok $add->execute('widgets'), 'Add change "widgets" to all plans';
    ok $_->plan->get('widgets'), 'Should have "widgets" in ' . $_->engine_key . ' plan'
         for @targets;
    file_exists_ok $_ for @scripts;

    is_deeply my $info = MockOutput->get_info, [
        (map { [__x 'Created {file}', file => $_] } @scripts),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[0]->plan_file,
        ],
        (map { [__x 'Skipped {file}: already exists', file => $_] } @scripts),
        [
            __x 'Added "{change}" to {file}',
            change => 'widgets',
            file   => $targets[1]->plan_file,
        ],
    ], 'Info should have script creations and skips';
    chdir File::Spec->updir;
}

##############################################################################
# Test options parsing.
can_ok $CLASS, 'options', '_parse_opts';
ok $add = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object again";
is_deeply $add->_parse_opts, {}, 'Base _parse_opts should return an empty hash';

is_deeply $add->_parse_opts([1]), {
    with_scripts => { deploy => 1, verify => 1, revert => 1 },
}, '_parse_opts() hould use options spec';
my $args = [qw(
    --note foo
    --template bar
    whatever
)];
is_deeply $add->_parse_opts($args), {
    note          => ['foo'],
    template_name => 'bar',
    with_scripts  => { deploy => 1, verify => 1, revert => 1 },
}, '_parse_opts() should parse options spec';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';

# Make sure --set works.
push @{ $args }, '--set' => 'schema=foo', '--set' => 'table=bar';
is_deeply $add->_parse_opts($args), {
    set => { schema => 'foo', table => 'bar' },
    with_scripts => { deploy => 1, verify => 1, revert => 1 },
}, '_parse_opts() should parse --set options';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';

# make sure --set works with repeating keys.
push @{ $args }, '--set' => 'column=id', '--set' => 'column=name';
is_deeply $add->_parse_opts($args), {
    set => { column => [qw(id name)] },
    with_scripts => { deploy => 1, verify => 1, revert => 1 },
}, '_parse_opts() should parse --set options with repeting key';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';

# Make sure --with and --use work.
push @{ $args }, qw(--with deploy --without verify --use),
    "foo=$tmpl";
is_deeply $add->_parse_opts($args), {
    with_scripts => { deploy => 1, verify => 0, revert => 1 },
    use => { foo => $tmpl }
}, '_parse_opts() should parse --with, --without, and --user';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';
