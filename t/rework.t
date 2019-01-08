#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 231;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use App::Sqitch::Command::add;
use Path::Class;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents qw(file_contents_identical file_contents_is files_eq);
use File::Path qw(make_path remove_tree);
use Test::NoWarnings;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::rework';
my $test_dir = dir 'test-rework';

my $config = TestConfig->new('core.engine' => 'sqlite');
ok my $sqitch = App::Sqitch->new(
    config  => $config,
    options => {
        top_dir => $test_dir->stringify,
    },
), 'Load a sqitch sqitch object';

isa_ok my $rework = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'rework',
    config  => $config,
}), $CLASS, 'rework command';
my $target = $rework->default_target;

sub dep($) {
    my $dep = App::Sqitch::Plan::Depend->new(
        conflicts => 0,
        %{ App::Sqitch::Plan::Depend->parse(shift) },
        plan      => $rework->default_target->plan,
    );
    $dep->project;
    return $dep;
}

can_ok $CLASS, qw(
    change_name
    requires
    conflicts
    note
    execute
);

is_deeply [$CLASS->options], [qw(
    change-name|change|c=s
    requires|r=s@
    conflicts|x=s@
    all|a!
    note|n|m=s@
    open-editor|edit|e!
)], 'Options should be set up';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {},
    'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    note      => [qw(hi there)],
}), {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    note      => [qw(hi there)],
}, 'Should have get requires, conflicts, and note options';

# open_editor handling
CONFIG: {
    my $config = TestConfig->from(local => File::Spec->catfile(qw(t rework.conf)));
    is_deeply $CLASS->configure($config, {}), {}, 'Grabs nothing from config';

    ok my $sqitch = App::Sqitch->new(config => $config), 'Load Sqitch project';
    isa_ok my $rework = App::Sqitch::Command->load({
        sqitch  => $sqitch,
        command => 'rework',
        config  => $config,
    }), $CLASS, 'rework command';
    ok $rework->open_editor, 'Coerces rework.open_editor from config string boolean';
}

##############################################################################
# Test attributes.
is_deeply $rework->requires, [], 'Requires should be an arrayref';
is_deeply $rework->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $rework->note, [], 'Note should be an arrayref';

##############################################################################
# Test execute().
make_path $test_dir->stringify;
END { remove_tree $test_dir->stringify if -e $test_dir->stringify };
my $plan_file = $target->plan_file;
my $fh = $plan_file->open('>') or die "Cannot open $plan_file: $!";
say $fh "%project=empty\n\n";
$fh->close or die "Error closing $plan_file: $!";

my $plan = $target->plan;

throws_ok { $rework->execute('foo') } 'App::Sqitch::X',
    'Should get an example for nonexistent change';
is $@->ident, 'plan', 'Nonexistent change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" does not exist in {file}.\n}
    . 'Use "sqitch add {change}" to add it to the plan',
    change => 'foo',
    file   => $plan->file,
), 'Fail message should say the step does not exist';

# Use the add command to create a step.
my $deploy_file = file qw(test-rework deploy foo.sql);
my $revert_file = file qw(test-rework revert foo.sql);
my $verify_file = file qw(test-rework verify foo.sql);

my $change_mocker = Test::MockModule->new('App::Sqitch::Plan::Change');
my %request_params;
$change_mocker->mock(request_note => sub {
    my $self = shift;
    %request_params = @_;
    return $self->note;
});

# Use the same plan.
my $mock_plan = Test::MockModule->new(ref $target);
$mock_plan->mock(plan => $plan);

ok my $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    change_name => 'foo',
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
ok $add->execute, 'Execute with the --change option';
file_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
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
ok $plan->tag( name => '@alpha' ), 'Tag it';

my $deploy_file2 = file qw(test-rework deploy foo@alpha.sql);
my $revert_file2 = file qw(test-rework revert foo@alpha.sql);
my $verify_file2 = file qw(test-rework verify foo@alpha.sql);
MockOutput->get_info;

file_not_exists_ok($_) for ($deploy_file2, $revert_file2, $verify_file2);
ok $rework->execute('foo'), 'Rework "foo"';

# The files should have been copied.
file_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
file_exists_ok($_) for ($deploy_file2, $revert_file2, $verify_file2);
file_contents_identical($deploy_file2, $deploy_file);
file_contents_identical($verify_file2, $verify_file);
file_contents_identical($revert_file, $deploy_file);
file_contents_is($revert_file2, <<'EOF', 'New revert should revert');
-- Revert empty:foo from sqlite

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF

# The note should have been required.
is_deeply \%request_params, {
    for => __ 'rework',
    scripts => [$deploy_file, $revert_file, $verify_file],
}, 'It should have prompted for a note';

# The plan file should have been updated.
ok $plan->load, 'Reload the plan file';
ok my @steps = $plan->changes, 'Get the steps';
is @steps, 2, 'Should have two steps';
is $steps[0]->name, 'foo', 'First step should be "foo"';
is $steps[1]->name, 'foo', 'Second step should also be "foo"';
is_deeply [$steps[1]->requires], [dep 'foo@alpha'],
    'Reworked step should require the previous step';

is_deeply +MockOutput->get_info, [
    [__x(
        'Added "{change}" to {file}.',
        change => 'foo [foo@alpha]',
        file   => $target->plan_file,
    )],
    [__n(
        'Modify this file as appropriate:',
        'Modify these files as appropriate:',
        3,
    )],
    ["  * $deploy_file"],
    ["  * $revert_file"],
    ["  * $verify_file"],
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
        dest => $verify_file2,
        src  => $verify_file,
    )],
    [__x(
        'Copied {src} to {dest}',
        dest => $revert_file,
        src  => $deploy_file,
    )],
], 'Debug should show file copying';

##############################################################################
# Let's do that again. This time with more dependencies and fewer files.
$deploy_file = file qw(test-rework deploy bar.sql);
$revert_file = file qw(test-rework revert bar.sql);
$verify_file = file qw(test-rework verify bar.sql);
ok $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates)),
    with_scripts => { revert => 0, verify => 0 },
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
$add->execute('bar');
file_exists_ok($deploy_file);
file_not_exists_ok($_) for ($revert_file, $verify_file);
ok $plan->tag( name => '@beta' ), 'Tag it with @beta';

my $deploy_file3 = file qw(test-rework deploy bar@beta.sql);
my $revert_file3 = file qw(test-rework revert bar@beta.sql);
my $verify_file3 = file qw(test-rework verify bar@beta.sql);
MockOutput->get_info;

isa_ok $rework = App::Sqitch::Command::rework->new(
    sqitch    => $sqitch,
    command   => 'rework',
    config    => $config,
    requires  => ['foo'],
    note      => [qw(hi there)],
    conflicts => ['dr_evil'],
), $CLASS, 'rework command with requirements and conflicts';

# Check the files.
file_not_exists_ok($_) for ($deploy_file3, $revert_file3, $verify_file3);
ok $rework->execute('bar'), 'Rework "bar"';
file_exists_ok($deploy_file);
file_not_exists_ok($_) for ($revert_file, $verify_file);
file_exists_ok($deploy_file3);
file_not_exists_ok($_) for ($revert_file3, $verify_file3);

# The note should have been required.
is_deeply \%request_params, {
    for => __ 'rework',
    scripts => [$deploy_file],
}, 'It should have prompted for a note';

# The plan file should have been updated.
ok $plan->load, 'Reload the plan file again';
ok @steps = $plan->changes, 'Get the steps';
is @steps, 4, 'Should have four steps';
is $steps[0]->name, 'foo', 'First step should be "foo"';
is $steps[1]->name, 'foo', 'Second step should also be "foo"';
is $steps[2]->name, 'bar', 'First step should be "bar"';
is $steps[3]->name, 'bar', 'Second step should also be "bar"';
is_deeply [$steps[3]->requires], [dep 'bar@beta', dep 'foo'],
    'Requires should have been passed to reworked change';
is_deeply [$steps[3]->conflicts], [dep '!dr_evil'],
    'Conflicts should have been passed to reworked change';
is $steps[3]->note, "hi\n\nthere",
    'Note should have been passed as comment';

is_deeply +MockOutput->get_info, [
    [__x(
        'Added "{change}" to {file}.',
        change => 'bar [bar@beta foo !dr_evil]',
        file   => $target->plan_file,
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
        dest => $verify_file3,
        src  => $verify_file,
    )],
    [__x(
        'Skipped {dest}: {src} does not exist',
        dest => $revert_file,
        src  => $revert_file3, # No previous revert, no need for new revert.
    )],
], 'Should have debug oputput for missing files';

# Make sure --open-editor works
MOCKSHELL: {
    my $sqitch_mocker = Test::MockModule->new('App::Sqitch');
    my $shell_cmd;
    $sqitch_mocker->mock(shell =>       sub { $shell_cmd = $_[1] });
    $sqitch_mocker->mock(quote_shell => sub { shift; join ' ' => @_ });

    ok $rework = $CLASS->new(
        sqitch              => $sqitch,
        template_directory  => Path::Class::dir(qw(etc templates)),
        note                => ['Testing --open-editor'],
        open_editor         => 1,
    ), 'Create another add with open_editor';

    ok $plan->tag( name => '@gamma' ), 'Tag it';

    my $rework_file = file qw(test-rework deploy bar.sql);
    my $deploy_file = file qw(test-rework deploy bar@gamma.sql);
    my $revert_file = file qw(test-rework revert bar@gamma.sql);
    my $verify_file = file qw(test-rework verify bar@gamma.sql);
    MockOutput->get_info;

    file_not_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
    ok $rework->execute('bar'), 'Rework "bar"';

    # The files should have been copied.
    file_exists_ok($_) for ($rework_file, $deploy_file);
    file_not_exists_ok($_) for ($revert_file, $verify_file);

    is $shell_cmd, join(' ', $sqitch->editor, $rework_file),
        'It should have prompted to edit sql files';

    is_deeply +MockOutput->get_info, [
        [__x(
            'Added "{change}" to {file}.',
            change => 'bar [bar@gamma]',
            file   => $target->plan_file,
        )],
        [__n(
            'Modify this file as appropriate:',
            'Modify these files as appropriate:',
            1,
        )],
        ["  * $rework_file"],
    ], 'And the info message should suggest editing the old files';
    MockOutput->get_debug; # empty debug.
};

# Make sure a configuration with multiple plans works.
$mock_plan->unmock('plan');
MULTIPLAN: {
    my $dstring = $test_dir->stringify;
    remove_tree $dstring;
    make_path $dstring;
    END { remove_tree $dstring if -e $dstring };
    chdir $dstring;

    my $conf = file 'multirework.conf';
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
    my %scripts = map {
        my $dir = dir $_;
        $dir->mkpath;
        $dir->file('sqitch.plan')->spew(join "\n",
            '%project=rework', '',
            'widgets 2012-07-16T17:25:07Z anna <a@n.na>',
            'gadgets 2012-07-16T18:25:07Z anna <a@n.na>',
            '@foo 2012-07-16T17:24:07Z julie <j@ul.ie>', '',
        );

        # Make the script files.
        my (@change, @reworked);
        for my $type (qw(deploy revert verify)) {
            my $subdir = $dir->subdir($type);
            $subdir->mkpath;
            my $script = $subdir->file('widgets.sql');
            $script->spew("-- $subdir widgets");
            push @change => $script;
            push @reworked => $subdir->file('widgets@foo.sql');
        }

        # Return the scripts.
        $_ => { change => \@change, reworked => \@reworked };
    } qw(pg sqlite mysql);

    # Load up the configuration for this project.
    my $config = TestConfig->from(local => $conf);
    my $sqitch = App::Sqitch->new(config => $config);
    ok my $rework = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another rework with custom multiplan config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 3, 'Should have three targets';

    # Make sure the target list matches our script list order (by engine).
    # pg always comes first, as primary engine, but the other two are random.
    push @targets, splice @targets, 1, 1 if $targets[1]->engine_key ne 'sqlite';

    # Let's do this thing!
    ok $rework->execute('widgets'), 'Rework change "widgets" in all plans';
    for my $target(@targets) {
        my $ekey = $target->engine_key;
        ok my $head = $target->plan->get('widgets@HEAD'),
            "Get widgets\@HEAD from the $ekey plan";
        ok my $foo = $target->plan->get('widgets@foo'),
            "Get widgets\@foo from the $ekey plan";
        cmp_ok $head->id, 'ne', $foo->id,
            "The two $ekey widgets should be different changes";
    }

    # All the files should exist, now.
    while (my ($k, $v) = each %scripts) {
        file_exists_ok $_ for map { @{ $v->{$_} } } qw(change reworked);
        # Deploy and verify files should be the same.
        files_eq $v->{change}[0], $v->{reworked}[0];
        files_eq $v->{change}[2], $v->{reworked}[2];
        # New revert should be the same as old deploy.
        files_eq $v->{change}[1], $v->{reworked}[0];
    }

    # Make sure we see the proper output.
    my $info = MockOutput->get_info;
    my $note = $request_params{scripts};
    my $ekey = $targets[1]->engine_key;
    if ($info->[1][0] !~ /$ekey/) {
        # Got the targets in a different order. So reorder results to match.
        ($info->[1], $info->[2]) = ($info->[2], $info->[1]);
        push @{ $info } => splice @{ $info }, 7, 3;
        push @{ $note } => splice @{ $note }, 3, 3;
    }
    is_deeply $note, [map { @{ $scripts{$_}{change} }} qw(pg sqlite mysql)],
        'Should have listed the files in the note prompt';
    is_deeply $info, [
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[0]->plan_file,
        )],
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[1]->plan_file,
        )],
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[2]->plan_file,
        )],
        [__n(
            'Modify this file as appropriate:',
            'Modify these files as appropriate:',
            3,
        )],
        map {
            map { ["  * $_" ] } @{ $scripts{$_}{change} }
        } qw(pg sqlite mysql)
    ], 'And the info message should show the two files to modify';

    my $debug = +MockOutput->get_debug;
    if ($debug->[4][0] !~ /$ekey/) {
        # Got the targets in a different order. So reorder results to match.
        push @{ $debug } => splice @{ $debug }, 4, 4;
    }
    is_deeply $debug, [
        map {
            my ($c, $r) = @{ $scripts{$_} }{qw(change reworked)};
            (
                map { [__x(
                    'Copied {src} to {dest}',
                    src  => $c->[$_],
                    dest => $r->[$_],
                )] } (0..2)
            ),
            [__x(
                'Copied {src} to {dest}',
                src  => $c->[0],
                dest => $c->[1],
            )]
        } qw(pg sqlite mysql)
    ], 'Should have debug oputput for all copied files';

    # # Make sure we get an error using --all and a target arg.
    throws_ok { $rework->execute('foo', 'pg' ) } 'App::Sqitch::X',
        'Should get an error for --all and a target arg';
    is $@->ident, 'rework', 'Mixed arguments error ident should be "rework"';
    is $@->message, __(
        'Cannot specify both --all and engine, target, or plan arugments'
    ), 'Mixed arguments error message should be correct';

    # # Now try reworking a change to just one engine. Remove --all
    %scripts = map {
        my $dir = dir $_;
        $dir->mkpath;

        # Make the script files.
        my (@change, @reworked);
        for my $type (qw(deploy revert verify)) {
            my $subdir = $dir->subdir($type);
            $subdir->mkpath;
            my $script = $subdir->file('gadgets.sql');
            $script->spew("-- $subdir gadgets");
            push @change => $script;
            # Only SQLite is reworked.
            push @reworked => $subdir->file('gadgets@foo.sql')
                if $_ eq 'sqlite';
        }

        # Return the scripts.
        $_ => { change => \@change, reworked => \@reworked };
    } qw(pg sqlite mysql);

    ok $rework = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create yet another rework with custom multiplan config';

    ok $rework->execute('gadgets', 'sqlite'),
        'Rework change "gadgets" in the sqlite plan';
    my %targets = map { $_->engine_key => $_ }
        App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is keys %targets, 3, 'Should still have three targets';
    my $name = 'gadgets@foo';
    for my $ekey(qw(pg mysql)) {
        my $target = $targets{$ekey};
        ok my $head = $target->plan->get('gadgets@HEAD'),
            "Get gadgets\@HEAD from the $ekey plan";
        ok my $foo = $target->plan->get('gadgets@foo'),
            "Get gadgets\@foo from the $ekey plan";
        cmp_ok $head->id, 'eq', $foo->id,
            "The two $ekey gadgets should be the same change";
    }
    do {
        my $ekey = 'sqlite';
        my $target = $targets{$ekey};
        ok my $head = $target->plan->get('gadgets@HEAD'),
            "Get gadgets\@HEAD from the $ekey plan";
        ok my $foo = $target->plan->get('gadgets@foo'),
            "Get gadgets\@foo from the $ekey plan";
        cmp_ok $head->id, 'ne', $foo->id,
            "The two $ekey gadgets should be different changes";
    };

    # All the files should exist, now.
    while (my ($k, $v) = each %scripts) {
        file_exists_ok $_ for map { @{ $v->{$_} } } qw(change reworked);
        next if $k ne 'sqlite';
        # Deploy and verify files should be the same.
        files_eq $v->{change}[0], $v->{reworked}[0];
        files_eq $v->{change}[2], $v->{reworked}[2];
        # New revert should be the same as old deploy.
        files_eq $v->{change}[1], $v->{reworked}[0];
    }

    is_deeply \%request_params, {
        for => __ 'rework',
        scripts => $scripts{sqlite}{change},
    }, 'Should have listed SQLite scripts in the note prompt';

    # Clear the output.
    MockOutput->get_info;
    MockOutput->get_debug;
    chdir File::Spec->updir;
}

# Make sure we update only one plan but write out multiple target files.
MULTITARGET: {
    my $dstring = $test_dir->stringify;
    remove_tree $dstring;
    make_path $dstring;
    END { remove_tree $dstring if -e $dstring };
    chdir $dstring;

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
    file('sqitch.plan')->spew(join "\n",
        '%project=rework', '',
        'widgets 2012-07-16T17:25:07Z anna <a@n.na>',
        'gadgets 2012-07-16T18:25:07Z anna <a@n.na>',
        '@foo 2012-07-16T17:24:07Z julie <j@ul.ie>', '',
    );

    # Create the scripts.
    my %scripts = map {
        my $dir = dir $_;
        my (@change, @reworked);
        for my $type (qw(deploy revert verify)) {
            my $subdir = $dir->subdir($type);
            $subdir->mkpath;
            my $script = $subdir->file('widgets.sql');
            $script->spew("-- $subdir widgets");
            push @change => $script;
            push @reworked => $subdir->file('widgets@foo.sql');
        }

        # Return the scripts.
        $_ => { change => \@change, reworked => \@reworked };
    } qw(pg sqlite);

    # Load up the configuration for this project.
    $config = TestConfig->from(local => $conf);
    $sqitch = App::Sqitch->new(config => $config);
    ok my $rework = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another rework with custom multiplan config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 2, 'Should have two targets';
    is $targets[0]->plan_file, $targets[1]->plan_file,
        'Targets should use the same plan file';
    my $target = $targets[0];

    # Let's do this thing!
    ok $rework->execute('widgets'), 'Rework change "widgets" in all plans';

    ok my $head = $target->plan->get('widgets@HEAD'),
        "Get widgets\@HEAD from the plan";
    ok my $foo = $target->plan->get('widgets@foo'),
        "Get widgets\@foo from the plan";
    cmp_ok $head->id, 'ne', $foo->id,
        "The two widgets should be different changes";

    # All the files should exist, now.
    while (my ($k, $v) = each %scripts) {
        file_exists_ok $_ for map { @{ $v->{$_} } } qw(change reworked);
        # Deploy and verify files should be the same.
        files_eq $v->{change}[0], $v->{reworked}[0];
        files_eq $v->{change}[2], $v->{reworked}[2];
        # New revert should be the same as old deploy.
        files_eq $v->{change}[1], $v->{reworked}[0];
    }

    is_deeply \%request_params, {
        for => __ 'rework',
        scripts => [ map {@{ $scripts{$_}{change} }} qw(pg sqlite)],
    }, 'Should have listed all the files to edit in the note prompt';

    # And the output should be correct.
    is_deeply +MockOutput->get_info, [
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $target->plan_file,
        )],
        [__n(
            'Modify this file as appropriate:',
            'Modify these files as appropriate:',
            3,
        )],
        map {
            map { ["  * $_" ] } @{ $scripts{$_}{change} }
        } qw(pg sqlite)
    ], 'And the info message should show the two files to modify';

    # As should the debug output
    is_deeply +MockOutput->get_debug, [
        map {
            my ($c, $r) = @{ $scripts{$_} }{qw(change reworked)};
            (
                map { [__x(
                    'Copied {src} to {dest}',
                    src  => $c->[$_],
                    dest => $r->[$_],
                )] } (0..2)
            ),
            [__x(
                'Copied {src} to {dest}',
                src  => $c->[0],
                dest => $c->[1],
            )]
        } qw(pg sqlite)
    ], 'Should have debug oputput for all copied files';

    chdir File::Spec->updir;
}

# Try two plans with different tags.
MULTITAG: {
    my $dstring = $test_dir->stringify;
    remove_tree $dstring;
    make_path $dstring;
    END { remove_tree $dstring if -e $dstring };
    chdir $test_dir->stringify;

    my $conf = file 'multirework.conf';
    $conf->spew(join "\n",
        '[core]',
        'engine = pg',
        '[engine "pg"]',
        'top_dir = pg',
        '[engine "sqlite"]',
        'top_dir = sqlite',
    );

    # Create plan files and determine the scripts that to be created.
    my %scripts = map {
        my $dir = dir $_;
        $dir->mkpath;
        my $tag = $_ eq 'pg' ? 'foo' : 'bar';
        $dir->file('sqitch.plan')->spew(join "\n",
            '%project=rework', '',
            'widgets 2012-07-16T17:25:07Z anna <a@n.na>',
            "\@$tag 2012-07-16T17:24:07Z julie <j\@ul.ie>", '',
        );

        # Make the script files.
        my (@change, @reworked);
        for my $type (qw(deploy revert verify)) {
            my $subdir = $dir->subdir($type);
            $subdir->mkpath;
            my $script = $subdir->file('widgets.sql');
            $script->spew("-- $subdir widgets");
            push @change => $script;
            push @reworked => $subdir->file("widgets\@$tag.sql");
        }

        # Return the scripts.
        $_ => { change => \@change, reworked => \@reworked };
    } qw(pg sqlite);

    # Load up the configuration for this project.
    $config = TestConfig->from(local => $conf);
    $sqitch = App::Sqitch->new(config => $config);
    ok my $rework = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another rework with custom multiplan config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 2, 'Should have two targets';

    # Let's do this thing!
    ok $rework->execute('widgets'), 'Rework change "widgets" in all plans';
    for my $target(@targets) {
        my $ekey = $target->engine_key;
        my $tag = $ekey eq 'pg' ? 'foo' : 'bar';
        ok my $head = $target->plan->get('widgets@HEAD'),
            "Get widgets\@HEAD from the $ekey plan";
        ok my $prev = $target->plan->get("widgets\@$tag"),
            "Get widgets\@$tag from the $ekey plan";
        cmp_ok $head->id, 'ne', $prev->id,
            "The two $ekey widgets should be different changes";
    }

    is_deeply \%request_params, {
        for => __ 'rework',
        scripts => [ map {@{ $scripts{$_}{change} }} qw(pg sqlite)],
    }, 'Should have listed all the files to edit in the note prompt';

    # And the output should be correct.
    is_deeply +MockOutput->get_info, [
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[0]->plan_file,
        )],
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@bar]',
            file   => $targets[1]->plan_file,
        )],
        [__n(
            'Modify this file as appropriate:',
            'Modify these files as appropriate:',
            2,
        )],
        map {
            map { ["  * $_" ] } @{ $scripts{$_}{change} }
        } qw(pg sqlite)
    ], 'And the info message should show the two files to modify';

    # As should the debug output
    is_deeply +MockOutput->get_debug, [
        map {
            my ($c, $r) = @{ $scripts{$_} }{qw(change reworked)};
            (
                map { [__x(
                    'Copied {src} to {dest}',
                    src  => $c->[$_],
                    dest => $r->[$_],
                )] } (0..2)
            ),
            [__x(
                'Copied {src} to {dest}',
                src  => $c->[0],
                dest => $c->[1],
            )]
        } qw(pg sqlite)
    ], 'Should have debug oputput for all copied files';

    chdir File::Spec->updir;
}

# Make sure we're okay with multiple plans sharing the same top dir.
ONETOP: {
    remove_tree $test_dir->stringify;
    make_path $test_dir->stringify;
    END { remove_tree $test_dir->stringify };
    chdir $test_dir->stringify;
    my $conf = file 'multirework.conf';
    $conf->spew(join "\n",
        '[core]',
        'engine = pg',
        '[engine "pg"]',
        'plan_file = pg.plan',
        '[engine "sqlite"]',
        'plan_file = sqlite.plan',
    );

    # Write the two plan files.
    file("$_.plan")->spew(join "\n",
        '%project=rework', '',
        'widgets 2012-07-16T17:25:07Z anna <a@n.na>',
        '@foo 2012-07-16T17:24:07Z julie <j@ul.ie>', '',
    ) for qw(pg sqlite);

    # One set of scripts for both.
    my (@change, @reworked);
    for my $type (qw(deploy revert verify)) {
        my $dir = dir $type;
        $dir->mkpath;
        my $script = $dir->file('widgets.sql');
        $script->spew("-- $dir widgets");
        push @change => $script;
        push @reworked => $dir->file('widgets@foo.sql');
    }

    # Load up the configuration for this project.
    $config = TestConfig->from(local => $conf);
    $sqitch = App::Sqitch->new(config => $config);
    ok my $rework = $CLASS->new(
        sqitch             => $sqitch,
        note               => ['Testing multiple plans'],
        all                => 1,
        template_directory => dir->parent->subdir(qw(etc templates))
    ), 'Create another rework with custom multiplan config';

    my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
    is @targets, 2, 'Should have two targets';

    ok $rework->execute('widgets'), 'Rework change "widgets" in all plans';
    for my $target(@targets) {
        my $ekey = $target->engine_key;
        ok my $head = $target->plan->get('widgets@HEAD'),
            "Get widgets\@HEAD from the $ekey plan";
        ok my $foo = $target->plan->get('widgets@foo'),
            "Get widgets\@foo from the $ekey plan";
        cmp_ok $head->id, 'ne', $foo->id,
            "The two $ekey widgets should be different changes";
    }

    # Make sure the files were written properly.
    file_exists_ok $_ for (@change, @reworked);
    # Deploy and verify files should be the same.
    files_eq $change[0], $reworked[0];
    files_eq $change[2], $reworked[2];
    # New revert should be the same as old deploy.
    files_eq $change[1], $reworked[0];

    is_deeply \%request_params, {
        for => __ 'rework',
        scripts => \@change,
    }, 'Should have listed the files to edit in the note prompt';

    # And the output should be correct.
    is_deeply +MockOutput->get_info, [
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[0]->plan_file,
        )],
        [__x(
            'Added "{change}" to {file}.',
            change => 'widgets [widgets@foo]',
            file   => $targets[1]->plan_file,
        )],
        [__n(
            'Modify this file as appropriate:',
            'Modify these files as appropriate:',
            2,
        )],
        map { ["  * $_" ] } @change,
    ], 'And the info message should show the two files to modify';

    # As should the debug output
    is_deeply +MockOutput->get_debug, [
        (
            map { [__x(
                'Copied {src} to {dest}',
                src  => $change[$_],
                dest => $reworked[$_],
            )] } (0..2)
        ),
        [__x(
            'Copied {src} to {dest}',
            src  => $change[0],
            dest => $change[1],
        )],
    ], 'Should have debug oputput for all copied files';

    chdir File::Spec->updir;
}
