#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 25;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Path::Class;
use URI;
use DateTime;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::status';

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
    options
    execute
    emit_state
    emit_changes
    emit_tags
    emit_status
);

#######################################################################################
# Test emit_state().
my $dt = DateTime->new(
    year       => 2012,
    month      => 7,
    day        => 5,
    hour       => 16,
    minute     => 12,
    second     => 47,
    time_zone => 'UTC',
);

my $state = {
    change_id   => 'someid',
    change      => 'widgets_table',
    deployed_by => 'fred',
    deployed_at => $dt->clone,
    tags        => [],
};
$dt->set_time_zone('local');
my $ts = $dt->iso8601;

ok $status->emit_state($state), 'Emit the state';
is_deeply +MockOutput->get_comment, [
    [__x 'Change: {change_id}', change_id => 'someid'],
    [__x 'Name:   {change}',    change    => 'widgets_table'],
    [__x 'User:   {name}',      name      => 'fred'],
    [__x 'Date:   {date}',      date      => $ts],
], 'The state should have been emitted';

# Try with a tag.
$state->{tags} = ['@alpha'];
ok $status->emit_state($state), 'Emit the state with a tag';
is_deeply +MockOutput->get_comment, [
    [__x 'Change: {change_id}', change_id => 'someid'],
    [__x 'Name:   {change}',    change    => 'widgets_table'],
    [__nx 'Tag:    {tags}', 'Tags:   {tags}', 1, tags => '@alpha'],
    [__x 'User:   {name}',      name      => 'fred'],
    [__x 'Date:   {date}',      date      => $ts],
], 'The state should have been emitted with a tag';

# Try with mulitple tags.
$state->{tags} = ['@alpha', '@beta', '@gamma'];
ok $status->emit_state($state), 'Emit the state with multiple tags';
is_deeply +MockOutput->get_comment, [
    [__x 'Change: {change_id}', change_id => 'someid'],
    [__x 'Name:   {change}',    change    => 'widgets_table'],
    [__nx 'Tag:    {tags}', 'Tags:   {tags}', 3,
     tags => join(__ ', ', qw(@alpha @beta @gamma))],
    [__x 'User:   {name}',      name      => 'fred'],
    [__x 'Date:   {date}',      date      => $ts],
], 'The state should have been emitted with multiple tags';

##############################################################################
# Test emit_status().
my $file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
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
