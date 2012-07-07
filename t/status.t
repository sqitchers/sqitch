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
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::status';
require_ok $CLASS;

my $uri = URI->new('https://github.com/theory/sqitch/');
ok my $sqitch = App::Sqitch->new(
    uri     => $uri,
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
    day        => 5,
    hour       => 16,
    minute     => 12,
    second     => 47,
    time_zone => 'America/Denver',
);

my $state = {
    change_id   => 'someid',
    change      => 'widgets_table',
    deployed_by => 'fred',
    deployed_at => $dt->clone,
    tags        => [],
};
$dt->set_time_zone('local');
my $ts = $dt->as_string( format => $status->date_format );

ok $status->emit_state($state), 'Emit the state';
is_deeply +MockOutput->get_comment, [
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name}',      name      => 'fred'],
], 'The state should have been emitted';

# Try with a tag.
$state-> {tags} = ['@alpha'];
ok $status->emit_state($state), 'Emit the state with a tag';
is_deeply +MockOutput->get_comment, [
    [__x 'Change:   {change_id}', change_id => 'someid'],
    [__x 'Name:     {change}',    change    => 'widgets_table'],
    [__nx 'Tag:      {tags}', 'Tags:     {tags}', 1, tags => '@alpha'],
    [__x 'Deployed: {date}',      date      => $ts],
    [__x 'By:       {name}',      name      => 'fred'],
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
    [__x 'By:       {name}',      name      => 'fred'],
], 'The state should have been emitted with multiple tags';

##############################################################################
# Test emit_changes().
my $engine_mocker = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @current_changes;
$engine_mocker->mock(current_changes => sub { sub { shift @current_changes } });
@current_changes = ({
    change_id   => 'someid',
    change      => 'foo',
    deployed_by => 'anna',
    deployed_at => $dt,
});
$sqitch = App::Sqitch->new(uri => $uri, _engine  => 'sqlite');
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
    ["  foo - $ts - anna"],
], 'Should have emitted one change';

# Add a couple more changes.
@current_changes = (
    {
        change_id   => 'someid',
        change      => 'foo',
        deployed_by => 'anna',
        deployed_at => $dt,
    },
    {
        change_id   => 'anid',
        change      => 'blech',
        deployed_by => 'david',
        deployed_at => $dt,
    },
    {
        change_id   => 'anotherid',
        change      => 'long_name',
        deployed_by => 'julie',
        deployed_at => $dt,
    },
);

ok $status->emit_changes, 'Emit changes thrice';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Change:', 'Changes:', 3],
    ["  foo       - $ts - anna"],
    ["  blech     - $ts - david"],
    ["  long_name - $ts - julie"],
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
    tag_id     => 'tagid',
    tag        => '@alpha',
    applied_by => 'duncan',
    applied_at => $dt,
});

ok $status->emit_tags, 'Emit tags';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Tag:', 'Tags:', 1],
    ["  \@alpha - $ts - duncan"],
], 'Should have emitted one tag';

# Add a couple more tags.
@current_tags = (
    {
        tag_id     => 'tagid',
        tag        => '@alpha',
        applied_by => 'duncan',
        applied_at => $dt,
    },
    {
        tag_id     => 'myid',
        tag        => '@beta',
        applied_by => 'nick',
        applied_at => $dt,
    },
    {
        tag_id     => 'yourid',
        tag        => '@gamma',
        applied_by => 'jacqueline',
        applied_at => $dt,
    },
);

ok $status->emit_tags, 'Emit tags again';
is_deeply +MockOutput->get_comment, [
    [''],
    [__n 'Tag:', 'Tags:', 3],
    ["  \@alpha - $ts - duncan"],
    ["  \@beta  - $ts - nick"],
    ["  \@gamma - $ts - jacqueline"],
], 'Should have emitted all three tags';

##############################################################################
# Test emit_status().
my $file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri, _engine  => 'sqlite');
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
    [__x 'By:       {name}',      name      => 'fred'],
    [''],
], 'The state should have been emitted';
is_deeply +MockOutput->get_emit, [
    [__n 'Undeployed change:', 'Undeployed changes:', 2],
    map { ['  * ', $_->format_name_with_tags] } @changes[2..$#changes],
], 'Should emit list of undeployed changes';

# Test with no chnages.
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
