#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 14;
# use Test::More 'no_plan';
use Test::MockModule;
use Test::Exception;

# For testing paths in App::Sqitch::Role::DBIEngine that are not implicictly
# tested by the engines that use it.

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Role::DBIEngine';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    _dt
    _log_tags_param
    _log_requires_param
    _log_conflicts_param
    _ts_default
    _can_limit
    _limit_default
    _simple_from
    _quote_idents
    _in_expr
    _register_release
    _version_query
    registry_version
    _cid
    earliest_change_id
    latest_change_id
    _select_state
    current_state
    current_changes
    current_tags
    search_events
    _regex_expr
    _limit_offset
    registered_projects
    register_project
    is_deployed_change
    are_deployed_changes
    is_deployed_tag
    _multi_values
    _dependency_placeholders
    _tag_placeholders
    _tag_subselect_columns
    _prepare_to_log
    log_deploy_change
    log_fail_change
    _log_event
    changes_requiring_change
    name_for_change_id
    log_new_tags
    log_revert_change
    deployed_changes
    deployed_changes_since
    load_change
    _offset_op
    change_id_offset_from_id
    change_offset_from_id
    _cid_head
    change_id_for
    _update_script_hashes
    begin_work
    finish_work
    rollback_work
);

is App::Sqitch::Role::DBIEngine::_ts_default, 'DEFAULT',
    '_ts_default shoudld return DEFAULT';

# Test various failure modes.
my $role = bless {} => $CLASS;
FAILMOCKS: {
    # Set up mocks.
    my $mock = Test::MockModule->new($CLASS);
    my ($dbh_err, $no_table, $no_col, $init) = ('OW', 0, 0, 0);
    my ($state_err, $sel_state) = ('OOPS', -1);
    $mock->mock(dbh => sub { die $dbh_err });
    $mock->mock(_no_table_error => sub { $no_table });
    $mock->mock(initialized => sub { $init });
    $mock->mock(_no_column_error => sub { $no_col });
    $mock->mock(_select_state => sub { $sel_state = $_[2]; die $state_err });

    # Test registry_version.
    throws_ok { $role->registry_version } qr/OW/,
        'registry_version should propagate non-table error';
    $no_table = 1;
    ok !$role->registry_version,
        'registry_version should return false on no-table error';
    $no_table = 0;

    # Test _cid
    throws_ok { $role->_cid(0, 0, 'foo') } qr/OW/,
        '_cid should propagate non-table error';
    $no_table = 1;
    ok !$role->_cid(0, 0, 'foo'),
        '_cid should return false on no-table error and unititialized';
    $no_table = 0;


    # Test current_state.
    throws_ok { $role->current_state('foo') } qr/OOPS/,
        'curent_state should propagate _select_state error';
    is $sel_state, 1, 'Should have passed 1 to _select_state';
    ($sel_state, $no_table) = (-1, 1);
    ok !$role->current_state('foo'),
        'curent_state should return false on no-table error';
    is $sel_state, 1, 'Should again have passed 1 to _select_state';
    ($sel_state, $init, $no_col) = (-1, 1, 1);
    throws_ok { $role->current_state('foo') } qr/OOPS/,
        'curent_state should propagate second error on no-column error';
    is $sel_state, 0, 'Should again have passed 0 to _select_state';
    ($sel_state, $no_table, $init, $no_col) = (-1, 0, 0, 0);

    # Make sure change_id_for returns undef when no useful params.
    $mock->mock(dbh => 1);
    is $role->change_id_for(project => 'foo'), undef,
        'Should get undef from change_id_for when no useful params';
}

done_testing;
