#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 113;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;
use Path::Class;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::status';
require_ok $CLASS;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

ok my $sqitch = App::Sqitch->new(
    options => {
        engine  => 'sqlite',
        top_dir => Path::Class::Dir->new('test-status'),
    },
), 'Load a sqitch object';
my $config = $sqitch->config;
isa_ok my $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
}), $CLASS, 'status command';

can_ok $status, qw(
    project
    show_changes
    show_tags
    date_format
    options
    execute
    configure
    emit_state
    emit_changes
    emit_tags
    emit_status
);

is_deeply [ $CLASS->options ], [qw(
    project=s
    target|t=s
    show-tags
    show-changes
    date-format|date=s
)], 'Options should be correct';

my $engine_mocker = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @projs;
$engine_mocker->mock( registered_projects => sub { @projs });
my $initialized;
$engine_mocker->mock( initialized => sub {
    diag "Gonna return $initialized" if $ENV{RELEASE_TESTING};
    $initialized;
} );

my $mock_target = Test::MockModule->new('App::Sqitch::Target');
my ($target, $orig_new);
$mock_target->mock(new => sub { $target = shift->$orig_new(@_); });
$orig_new = $mock_target->original('new');

# Start with uninitialized database.
$initialized = 0;

##############################################################################
# Test project.
$status->target($status->default_target);
throws_ok { $status->project } 'App::Sqitch::X',
    'Should have error for uninitialized database';
is $@->ident, 'status', 'Uninitialized database error ident should be "status"';
is $@->message, __(
    'Database not initialized for Sqitch'
), 'Uninitialized database error message should be correct';

# Specify a project.
isa_ok $status = $CLASS->new(
    sqitch  => $sqitch,
    project => 'foo',
), $CLASS, 'new status command';
is $status->project, 'foo', 'Should have project "foo"';

# Look up the project in the database.
ok $sqitch = App::Sqitch->new(
    options => {
        engine  => 'sqlite',
        top_dir => Path::Class::Dir->new('test-status')->stringify,
    },
), 'Load a sqitch object with SQLite';

ok $status = $CLASS->new(sqitch => $sqitch), 'Create another status command';
$status->target($status->default_target);
throws_ok { $status->project } 'App::Sqitch::X',
    'Should get an error for uninitialized db';
is $@->ident, 'status', 'Uninitialized db error ident should be "status"';
is $@->message, __ 'Database not initialized for Sqitch',
    'Uninitialized db error message should be correct';

# Try no registered projects.
$initialized = 1;
throws_ok { $status->project } 'App::Sqitch::X',
    'Should get an error for no registered projects';
is $@->ident, 'status', 'No projects error ident should be "status"';
is $@->message, __ 'No projects registered',
    'No projects error message should be correct';

# Try too many registered projects.
@projs = qw(foo bar);
throws_ok { $status->project } 'App::Sqitch::X',
    'Should get an error for too many projects';
is $@->ident, 'status', 'Too many projects error ident should be "status"';
is $@->message, __x(
    'Use --project to select which project to query: {projects}',
    projects => join __ ', ', @projs,
), 'Too many projects error message should be correct';

# Go for one project.
@projs = ('status');
is $status->project, 'status', 'Should find single project';
$engine_mocker->unmock_all;

# Fall back on plan project name.
ok $sqitch = App::Sqitch->new(
    options => { top_dir => Path::Class::Dir->new(qw(t sql))->stringify },
), 'Load another sqitch object';

isa_ok $status = $CLASS->new( sqitch => $sqitch ), $CLASS,
    'another status command';
$status->target($status->default_target);
is $status->project, $target->plan->project, 'Should have plan project';

##############################################################################
# Test database.
is $status->target_name, undef, 'Default target should be undef';
isa_ok $status = $CLASS->new(
    sqitch      => $sqitch,
    target_name => 'foo',
), $CLASS, 'new status with target';
is $status->target_name, 'foo', 'Should have target "foo"';

##############################################################################
# Test configure().
my $cmock = Test::MockModule->new('App::Sqitch::Config');
is_deeply $CLASS->configure($config, {}), {},
    'Should get empty hash for no config or options';
$cmock->mock( get => 'nonesuch' );
throws_ok { $CLASS->configure($config, {}), {} } 'App::Sqitch::X',
    'Should get error for invalid date format in config';
is $@->ident, 'datetime',
    'Invalid date format error ident should be "datetime"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'nonesuch',
), 'Invalid date format error message should be correct';
$cmock->unmock_all;

throws_ok { $CLASS->configure($config, { date_format => 'non'}), {} }
    'App::Sqitch::X',
    'Should get error for invalid date format in optsions';
is $@->ident, 'datetime',
    'Invalid date format error ident should be "status"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'non',
), 'Invalid date format error message should be correct';

##############################################################################
# Test emit_state().
my $dt = App::Sqitch::DateTime->new(
    year       => 2012,
    month      => 7,
    day        => 7,
    hour       => 16,
    minute     => 12,
    second     => 47,
    time_zone => 'America/Denver',
);

my $state = {
    project         => 'mystatus',
    change_id       => 'someid',
    change          => 'widgets_table',
    committer_name  => 'fred',
    committer_email => 'fred@example.com',
    committed_at    => $dt->clone,
    tags            => [],
    planner_name    => 'barney',
    planner_email   => 'barney@example.com',
    planned_at      => $dt->clone->subtract(days => 2),
};
$dt->set_time_zone('local');
my $ts = $dt->as_string( format => $status->date_format );

ok $status->emit_state($state), 'Emit the state';
is_deeply +MockOutput->get_comment, [
    [__x 'Project:  {project}', project => 'mystatus'],
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com' ],
], 'The state should have been emitted';

# Try with a tag.
$state-> {tags} = ['@alpha'];
ok $status->emit_state($state), 'Emit the state with a tag';
is_deeply +MockOutput->get_comment, [
    [__x 'Project:  {project}', project => 'mystatus'],
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__nx 'Tag:      {tags}', 'Tags:     {tags}', 1, tags => '@alpha'],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com' ],
], 'The state should have been emitted with a tag';

# Try with mulitple tags.
$state-> {tags} = ['@alpha', '@beta', '@gamma'];
ok $status->emit_state($state), 'Emit the state with multiple tags';
is_deeply +MockOutput->get_comment, [
    [__x 'Project:  {project}', project => 'mystatus'],
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__nx 'Tag:      {tags}', 'Tags:     {tags}', 3,
     tags => join(__ ', ', qw(@alpha @beta @gamma))],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com' ],
], 'The state should have been emitted with multiple tags';

##############################################################################
# Test emit_changes().
my @current_changes;
my $project;
$engine_mocker->mock(current_changes => sub {
    $project = $_[1];
    sub { shift @current_changes };
});
@current_changes = ({
    change_id       => 'someid',
    change          => 'foo',
    committer_name  => 'anna',
    committer_email => 'anna@example.com',
    committed_at    => $dt,
    planner_name    => 'anna',
    planner_email   => 'anna@example.com',
    planned_at      => $dt->clone->subtract( hours => 4 ),
});
$sqitch = App::Sqitch->new(options => { engine  => 'sqlite' });
ok $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
}), 'Create status command with an engine';

ok $status->emit_changes, 'Try to emit changes';
is_deeply +MockOutput->get_comment, [],
    'Should have emitted no changes';

ok $status = App::Sqitch::Command::status->new(
    sqitch       => $sqitch,
    show_changes => 1,
    project      => 'foo',
), 'Create change-showing status command';
$status->target($status->default_target);

ok $status->emit_changes, 'Emit changes again';
is $project, 'foo', 'Project "foo" should have been passed to current_changes';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Change:', 'Changes:', 1],
    ["  foo - $ts - anna <anna\@example.com>"],
], 'Should have emitted one change';

# Add a couple more changes.
@current_changes = (
    {
        change_id       => 'someid',
        change          => 'foo',
        committer_name  => 'anna',
        committer_email => 'anna@example.com',
        committed_at    => $dt,
        planner_name    => 'anna',
        planner_email   => 'anna@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
    {
        change_id       => 'anid',
        change          => 'blech',
        committer_name  => 'david',
        committer_email => 'david@example.com',
        committed_at    => $dt,
        planner_name    => 'david',
        planner_email   => 'david@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
    {
        change_id       => 'anotherid',
        change          => 'long_name',
        committer_name  => 'julie',
        committer_email => 'julie@example.com',
        committed_at    => $dt,
        planner_name    => 'julie',
        planner_email   => 'julie@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
);

ok $status->emit_changes, 'Emit changes thrice';
is $project, 'foo',
    'Project "foo" again should have been passed to current_changes';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Change:', 'Changes:', 3],
    ["  foo       - $ts - anna <anna\@example.com>"],
    ["  blech     - $ts - david <david\@example.com>"],
    ["  long_name - $ts - julie <julie\@example.com>"],
], 'Should have emitted three changes';

##############################################################################
# Test emit_tags().
my @current_tags;
$engine_mocker->mock(current_tags => sub {
    $project = $_[1];
    sub { shift @current_tags };
});

ok $status->emit_tags, 'Try to emit tags';
is_deeply +MockOutput->get_comment, [], 'No tags should have been emitted';

ok $status = App::Sqitch::Command::status->new(
    sqitch    => $sqitch,
    show_tags => 1,
    project   => 'bar',
), 'Create tag-showing status command';
$status->target($status->default_target);

# Try with no tags.
ok $status->emit_tags, 'Try to emit tags again';
is $project, 'bar', 'Project "bar" should be passed to current_tags()';
is_deeply +MockOutput->get_comment, [
    [''],
    [__ 'Tags: None.'],
], 'Should have emitted a header for no tags';

@current_tags = ({
    tag_id          => 'tagid',
    tag             => '@alpha',
    committer_name  => 'duncan',
    committer_email => 'duncan@example.com',
    committed_at    => $dt,
    planner_name    => 'duncan',
    planner_email   => 'duncan@example.com',
    planned_at      => $dt->clone->subtract( hours => 4 ),
});

ok $status->emit_tags, 'Emit tags';
is $project, 'bar', 'Project "bar" should again be passed to current_tags()';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Tag:', 'Tags:', 1],
    ["  \@alpha - $ts - duncan <duncan\@example.com>"],
], 'Should have emitted one tag';

# Add a couple more tags.
@current_tags = (
    {
        tag_id          => 'tagid',
        tag             => '@alpha',
        committer_name  => 'duncan',
        committer_email => 'duncan@example.com',
        committed_at    => $dt,
        planner_name    => 'duncan',
        planner_email   => 'duncan@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
    {
        tag_id          => 'myid',
        tag             => '@beta',
        committer_name  => 'nick',
        committer_email => 'nick@example.com',
        committed_at    => $dt,
        planner_name    => 'nick',
        planner_email   => 'nick@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
    {
        tag_id          => 'yourid',
        tag             => '@gamma',
        committer_name  => 'jacqueline',
        committer_email => 'jacqueline@example.com',
        committed_at    => $dt,
        planner_name    => 'jacqueline',
        planner_email   => 'jacqueline@example.com',
        planned_at      => $dt->clone->subtract( hours => 4 ),
    },
);

ok $status->emit_tags, 'Emit tags again';
is $project, 'bar', 'Project "bar" should once more be passed to current_tags()';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Tag:', 'Tags:', 3],
    ["  \@alpha - $ts - duncan <duncan\@example.com>"],
    ["  \@beta  - $ts - nick <nick\@example.com>"],
    ["  \@gamma - $ts - jacqueline <jacqueline\@example.com>"],
], 'Should have emitted all three tags';

##############################################################################
# Test emit_status().
my $file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(options => {
    plan_file => $file->stringify,
    engine  => 'sqlite',
});
ok $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,}), 'Create status command with actual plan command';
$status->target($target = $status->default_target);
my @changes = $target->plan->changes;

# Start with an up-to-date state.
$state->{change_id} = $changes[-1]->id;
ok $status->emit_status($state), 'Emit status';
is_deeply +MockOutput->get_comment, [['']], 'Should have a blank comment line';
is_deeply +MockOutput->get_emit, [
    [__ 'Nothing to deploy (up-to-date)'],
], 'Should emit up-to-date output';

# Start with second-to-last change.
$state->{change_id} = $changes[2]->id;
ok $status->emit_status($state), 'Emit status again';
is_deeply +MockOutput->get_comment, [['']], 'Should have a blank comment line';
is_deeply +MockOutput->get_emit, [
    [__n 'Undeployed change:', 'Undeployed changes:', 1],
    ['  * ', $changes[3]->format_name_with_tags],
], 'Should emit list of undeployed changes';

# Start with second step.
$state->{change_id} = $changes[1]->id;
ok $status->emit_status($state), 'Emit status thrice';
is_deeply +MockOutput->get_comment, [['']], 'Should have a blank comment line';
is_deeply +MockOutput->get_emit, [
    [__n 'Undeployed change:', 'Undeployed changes:', 2],
    map { ['  * ', $_->format_name_with_tags] } @changes[2..$#changes],
], 'Should emit list of undeployed changes';

# Now go for an ID that cannot be found.
$state->{change_id} = 'nonesuchid';
throws_ok { $status->emit_status($state) } 'App::Sqitch::X', 'Die on invalid ID';
is $@->ident, 'status', 'Invalid ID error ident should be "status"';
is $@->message, __ 'Make sure you are connected to the proper database for this project.',
    'The invalid ID error message should be correct';
is_deeply +MockOutput->get_comment, [['']], 'Should have a blank comment line';
is_deeply +MockOutput->get_vent, [
    [__x 'Cannot find this change in {file}', file => $file],
], 'Should have a message about inability to find the change';

##############################################################################
# Test execute().
my ($target_name_arg, $orig_meth);
$target_name_arg = '_blah';
$mock_target->mock(new => sub {
    my $self = shift;
    my %p = @_;
    $target_name_arg = $p{name};
    $self->$orig_meth(@_);
});
$orig_meth = $mock_target->original('new');

ok $status = App::Sqitch::Command::status->new(
    sqitch  => $sqitch,
    config  => $config,
), 'Recreate status command';

my $check_output = sub {
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    is_deeply +MockOutput->get_comment, [
        [__x 'On database {db}', db => $target->engine->destination ],
        [__x 'Project:  {project}', project => 'mystatus'],
        [__x 'Change:   {change_id}', change_id => $state->{change_id}],
        [__x 'Name:     {change}',    change    => 'widgets_table'],
        [__nx 'Tag:      {tags}', 'Tags:     {tags}', 3,
         tags => join(__ ', ', qw(@alpha @beta @gamma))],
        [__x 'Deployed: {date}',      date      => $ts],
        [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com'],
        [''],
    ], 'The state should have been emitted';
    is_deeply +MockOutput->get_emit, [
        [__n 'Undeployed change:', 'Undeployed changes:', 2],
        map { ['  * ', $_->format_name_with_tags] } @changes[2..$#changes],
    ], 'Should emit list of undeployed changes';
};


$state->{change_id} = $changes[1]->id;
$engine_mocker->mock( current_state => $state );
ok $status->execute, 'Execute';
$check_output->();
is $target_name_arg, undef, 'No target name should have been passed to Target';

# Test with a database argument.
ok $status->execute('db:sqlite:'), 'Execute with target arg';
$check_output->();
is $target_name_arg, 'db:sqlite:', 'Name "db:sqlite:" should have been passed to Target';

# Pass the database in an option.
ok $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
    args    => ['--target', 'db:sqlite:'],
}), 'Create status command with a target option';
ok $status->execute, 'Execute with target attribute';
$check_output->();
is $target_name_arg, 'db:sqlite:', 'Name "db:sqlite:" should have been passed to Target';

# Test with two targets.
ok $status->execute('whatever'), 'Execute with target attribute and arg';
$check_output->();
is $target_name_arg, 'db:sqlite:', 'Name "db:sqlite:" should have been passed to Target';
is_deeply +MockOutput->get_warn, [[__x(
    'Both the --target option and the target argument passed; using {option}',
    option => $status->target_name,
)]], 'Should have got warning for two targets';

# Test with unknown plan.
for my $spec (
    [ 'specified', App::Sqitch->new( options => { engine => 'sqlite' }) ],
    [ 'external', $sqitch ],
) {
    my ( $desc, $sqitch ) = @{ $spec };
    ok $status = $CLASS->new(
        sqitch  => $sqitch,
        project => 'foo',
    ), "Create status command with $desc project";

    ok $status->execute, "Execute for $desc project";
    is_deeply +MockOutput->get_comment, [
        [__x 'On database {db}', db => $target->engine->destination ],
        [__x 'Project:  {project}', project => 'mystatus'],
        [__x 'Change:   {change_id}', change_id => $state->{change_id}],
        [__x 'Name:     {change}',    change    => 'widgets_table'],
        [__nx 'Tag:      {tags}', 'Tags:     {tags}', 3,
         tags => join(__ ', ', qw(@alpha @beta @gamma))],
        [__x 'Deployed: {date}',      date      => $ts],
        [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com'],
        [''],
    ], "The $desc project state should have been emitted";
    is_deeply +MockOutput->get_emit, [
        [__x 'Status unknown. Use --plan-file to assess "{project}" status', project => 'foo'],
    ], "Should emit unknown status message for $desc project";
}

# Test with no changes.
$engine_mocker->mock( current_state => undef );
throws_ok { $status->execute } 'App::Sqitch::X', 'Die on no state';
is $@->ident, 'status', 'No state error ident should be "status"';
is $@->message, __ 'No changes deployed',
    'No state error message should be correct';
is_deeply +MockOutput->get_comment, [
    [__x 'On database {db}', db => $target->engine->destination ],
], 'The "On database" comment should have been emitted';

# Test with no initilization.
$initialized = 0;
$engine_mocker->mock( initialized => sub { $initialized } );
$engine_mocker->mock( current_state => sub { die 'No Sqitch tables' } );
throws_ok { $status->execute } 'App::Sqitch::X',
    'Should get an error for uninitialized db';
is $@->ident, 'status', 'Uninitialized db error ident should be "status"';
is $@->message, __x(
    'Database {db} has not been initialized for Sqitch',
    db => $status->engine->destination,
), 'Uninitialized db error message should be correct';
