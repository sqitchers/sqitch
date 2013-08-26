#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 80;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use App::Sqitch::Command::add;
use Path::Class;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents qw(file_contents_identical file_contents_is);
use File::Path qw(make_path remove_tree);
use Test::NoWarnings;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::rework';

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('sql'),
    _engine => 'pg',
), 'Load a sqitch sqitch object';

sub dep($) {
    my $dep = App::Sqitch::Plan::Depend->new(
        conflicts => 0,
        %{ App::Sqitch::Plan::Depend->parse(shift) },
        plan      => $sqitch->plan,
    );
    $dep->project;
    return $dep;
}

my $config = $sqitch->config;
isa_ok my $rework = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'rework',
    config  => $config,
}), $CLASS, 'rework command';

can_ok $CLASS, qw(
    requires
    conflicts
    note
    execute
);

is_deeply [$CLASS->options], [qw(
    requires|r=s@
    conflicts|c=s@
    note|n=s@
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

##############################################################################
# Test attributes.
is_deeply $rework->requires, [], 'Requires should be an arrayref';
is_deeply $rework->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $rework->note, [], 'Note should be an arrayref';

##############################################################################
# Test execute().
make_path 'sql';
END { remove_tree 'sql' };
my $plan_file = $sqitch->plan_file;
my $fh = $plan_file->open('>') or die "Cannot open $plan_file: $!";
say $fh "%project=empty\n\n";
$fh->close or die "Error closing $plan_file: $!";

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
my $verify_file = file qw(sql verify foo.sql);

my $change_mocker = Test::MockModule->new('App::Sqitch::Plan::Change');
my %request_params;
$change_mocker->mock(request_note => sub {
    shift;
    %request_params = @_;
});

ok my $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
$add->execute('foo');
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

my $deploy_file2 = file qw(sql deploy foo@alpha.sql);
my $revert_file2 = file qw(sql revert foo@alpha.sql);
my $verify_file2 = file qw(sql verify foo@alpha.sql);
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
-- Revert foo

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
        file   => $sqitch->plan_file,
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
$deploy_file = file qw(sql deploy bar.sql);
$revert_file = file qw(sql revert bar.sql);
$verify_file = file qw(sql verify bar.sql);
ok $add = App::Sqitch::Command::add->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates)),
    with_revert => 0,
    with_verify => 0,
), 'Create another add with template_directory';
file_not_exists_ok($_) for ($deploy_file, $revert_file, $verify_file);
$add->execute('bar');
file_exists_ok($deploy_file);
file_not_exists_ok($_) for ($revert_file, $verify_file);
ok $plan->tag( name => '@beta' ), 'Tag it with @beta';

my $deploy_file3 = file qw(sql deploy bar@beta.sql);
my $revert_file3 = file qw(sql revert bar@beta.sql);
my $verify_file3 = file qw(sql verify bar@beta.sql);
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
        dest => $verify_file3,
        src  => $verify_file,
    )],
    [__x(
        'Skipped {dest}: {src} does not exist',
        dest => $revert_file,
        src  => $revert_file3, # No previous revert, no need for new revert.
    )],
], 'Should have debug oputput for missing files';
