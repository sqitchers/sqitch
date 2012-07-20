#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 59;
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

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
}), $CLASS, 'status command';

can_ok $status, qw(
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

throws_ok { $CLASS->configure($config, { 'date-format' => 'non'}), {} }
    'App::Sqitch::X',
    'Should get error for invalid date format in optsions';
is $@->ident, 'datetime',
    'Invalid date format error ident should be "status"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'non',
), 'Invalid date format error message should be correct';

#######################################################################################
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
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com' ],
], 'The state should have been emitted';

# Try with a tag.
$state-> {tags} = ['@alpha'];
ok $status->emit_state($state), 'Emit the state with a tag';
is_deeply +MockOutput->get_comment, [
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
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__nx 'Tag:      {tags}', 'Tags:     {tags}', 3,
     tags => join(__ ', ', qw(@alpha @beta @gamma))],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name} <{email}>', name => 'fred', email => 'fred@example.com' ],
], 'The state should have been emitted with multiple tags';

##############################################################################
# Test emit_changes().
my $engine_mocker = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @current_changes;
$engine_mocker->mock(current_changes => sub { sub { shift @current_changes } });
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
$sqitch = App::Sqitch->new(_engine  => 'sqlite');
ok $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
}), 'Create status command with an engine';

ok $status->emit_changes, 'Try to emit changes';
is_deeply +MockOutput->get_comment, [],
    'Should have emitted no changes';

ok $status = App::Sqitch::Command::status->new(
    sqitch         => $sqitch,
    show_changes => 1,
), 'Create change-showing status command';

ok $status->emit_changes, 'Emit changes again';
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
$engine_mocker->mock(current_tags => sub { sub { shift @current_tags } });

ok $status->emit_tags, 'Try to emit tags';
is_deeply +MockOutput->get_comment, [], 'No tags should have been emitted';

ok $status = App::Sqitch::Command::status->new(
    sqitch       => $sqitch,
    show_tags    => 1,
), 'Create tag-showing status command';

# Try with no tags.
ok $status->emit_tags, 'Try to emit tags again';
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
$sqitch = App::Sqitch->new(plan_file => $file, _engine  => 'sqlite');
my @changes = $sqitch->plan->changes;
ok $status = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'status',
    config  => $config,
}), 'Create status command with actual plan command';

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
$state->{change_id} = $changes[1]->id;
$engine_mocker->mock( initialized => 1 );
$engine_mocker->mock( current_state => $state );
ok $status->execute, 'Execute';
is_deeply +MockOutput->get_comment, [
    [__x 'On database {db}', db => $sqitch->engine->destination ],
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

# Test with no changes.
$engine_mocker->mock( current_state => undef );
throws_ok { $status->execute } 'App::Sqitch::X', 'Die on no state';
is $@->ident, 'status', 'No state error ident should be "status"';
is $@->message, __ 'No changes deployed',
    'No state error message should be correct';

# Test with no initialization.
$engine_mocker->mock( current_state => $state );
$engine_mocker->mock( initialized => 0 );
throws_ok { $status->execute } 'App::Sqitch::X', 'Die on uninitialized';
is $@->ident, 'status', 'uninitialized error ident should be "status"';
is $@->message, __ 'No changes deployed',
    'uninitialized error message should be correct';
