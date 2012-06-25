#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Plan;
use URI;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::pg';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
}

is_deeply [$CLASS->config_vars], [
    client        => 'any',
    username      => 'any',
    password      => 'any',
    db_name       => 'any',
    host          => 'any',
    port          => 'int',
    sqitch_schema => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
isa_ok my $pg = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'psql' . ($^O eq 'Win32' ? '.exe' : '');
is $pg->client, $client, 'client should default to psql';
is $pg->sqitch_schema, 'sqitch', 'sqitch_schema default should be "sqitch"';
for my $attr (qw(username password db_name host port)) {
    is $pg->$attr, undef, "$attr default should be undef";
}

is $pg->destination, $ENV{PGDATABASE} || $ENV{PGUSER} || $ENV{USER},
    'Destination should fall back on environment variables';

my @std_opts = (
    '--quiet',
    '--no-psqlrc',
    '--no-align',
    '--tuples-only',
    '--set' => 'ON_ERROR_ROLLBACK=1',
    '--set' => 'ON_ERROR_STOP=1',
    '--set' => 'sqitch_schema=sqitch',
);
is_deeply [$pg->psql], [$client, @std_opts],
    'psql command should be std opts-only';

##############################################################################
# Test other configs for the destination.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{PGDATABASE};
    local $ENV{PGUSER};
    local $ENV{USER};
    for my $env (qw(PGDATABASE PGUSER USER)) {
        my $pg = $CLASS->new(sqitch => $sqitch);
        local $ENV{$env} = "\$ENV=whatever";
        is $pg->destination, "\$ENV=whatever", "Destination should read \$$env";
    }

    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->destination, 'hi', 'Destination should read username';

    $ENV{PGDATABASE} = 'mydb';
    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->destination, 'mydb', 'Destination should prefer $PGDATABASE to username';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.pg.client'        => '/path/to/psql',
    'core.pg.username'      => 'freddy',
    'core.pg.password'      => 's3cr3t',
    'core.pg.db_name'       => 'widgets',
    'core.pg.host'          => 'db.example.com',
    'core.pg.port'          => 1234,
    'core.pg.sqitch_schema' => 'meta',
);
$std_opts[-1] = 'sqitch_schema=meta';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $pg = $CLASS->new(sqitch => $sqitch), 'Create another pg';

is $pg->client, '/path/to/psql', 'client should be as configured';
is $pg->username, 'freddy', 'username should be as configured';
is $pg->password, 's3cr3t', 'password should be as configured';
is $pg->db_name, 'widgets', 'db_name should be as configured';
is $pg->destination, 'widgets', 'destination should default to db_name';
is $pg->host, 'db.example.com', 'host should be as configured';
is $pg->port, 1234, 'port should be as configured';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should be as configured';
is_deeply [$pg->psql], [qw(
    /path/to/psql
    --username freddy
    --dbname   widgets
    --host     db.example.com
    --port     1234
), @std_opts], 'psql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    'client'        => '/some/other/psql',
    'username'      => 'anna',
    'db_name'       => 'widgets_dev',
    'host'          => 'foo.com',
    'port'          => 98760,
    uri             => URI->new('https://github.com/theory/sqitch/'),
);

ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with sqitch with options';

is $pg->client, '/some/other/psql', 'client should be as optioned';
is $pg->username, 'anna', 'username should be as optioned';
is $pg->password, 's3cr3t', 'password should still be as configured';
is $pg->db_name, 'widgets_dev', 'db_name should be as optioned';
is $pg->destination, 'widgets_dev', 'destination should still default to db_name';
is $pg->host, 'foo.com', 'host should be as optioned';
is $pg->port, 98760, 'port should be as optioned';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should still be as configured';
is_deeply [$pg->psql], [qw(
    /some/other/psql
    --username anna
    --dbname   widgets_dev
    --host     foo.com
    --port     98760
), @std_opts], 'psql command should be as optioned';

##############################################################################
# Test _run() and _spool().
can_ok $pg, qw(_run _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

$exp_pass = 's3cr3t';
ok $pg->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $pg->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool()';

# Remove the password.
delete $config{'core.pg.password'};
ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with sqitch with no pw';
$exp_pass = undef;
ok $pg->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $pg->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool() again';

##############################################################################
# Test file and handle running.
ok $pg->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $pg->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $pg->psql],
    'Handle should be passed to spool()';
$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Can we do live tests?
can_ok $CLASS, qw(
    initialized
    initialize
    run_file
    run_handle
    log_deploy_step
    log_fail_step
    log_revert_step
    latest_step_id
    is_deployed_tag
    is_deployed_step
    check_requires
    check_conflicts
);

my @cleanup;
END {
    $pg->_dbh->do(
        "SET client_min_messages=warning; $_"
    ) for @cleanup;
}

subtest 'live database' => sub {
    $sqitch = App::Sqitch->new(
        username  => 'postgres',
        sql_dir   => Path::Class::dir(qw(t pg)),
        plan_file => Path::Class::file(qw(t pg sqitch.plan)),
        uri       => URI->new('https://github.com/theory/sqitch/'),
    );
    $pg = $CLASS->new(sqitch => $sqitch);
    try {
        $pg->_dbh;
    } catch {
        plan skip_all => "Unable to connect to a database for testing: $_";
    };

    plan 'no_plan';

    ok !$pg->initialized, 'Database should not yet be initialized';
    push @cleanup, 'DROP SCHEMA ' . $pg->sqitch_schema . ' CASCADE';
    ok $pg->initialize, 'Initialize the database';
    ok $pg->initialized, 'Database should now be initialized';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], 'sqitch',
        'The search path should be set';

    # Try it with a different schema name.
    ok $pg = $CLASS->new(
        sqitch => $sqitch,
        sqitch_schema => '__sqitchtest',
    ), 'Create a pg with postgres user and __sqitchtest schema';

    is $pg->latest_step_id, undef, 'No init, no steps';

    ok !$pg->initialized, 'Database should no longer seem initialized';
    push @cleanup, 'DROP SCHEMA __sqitchtest CASCADE';
    ok $pg->initialize, 'Initialize the database again';
    ok $pg->initialized, 'Database should be initialized again';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], '__sqitchtest',
        'The search path should be set to the new path';

    is $pg->latest_step_id, undef, 'Still no steps';

    # Make sure a second attempt to initialize dies.
    throws_ok { $pg->initialize } 'App::Sqitch::X',
        'Should die on existing schema';
    is $@->ident, 'pg', 'Mode should be "pg"';
    is $@->message, __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ), 'And it should show the proper schema in the error message';

    throws_ok { $pg->_dbh->do('INSERT blah INTO __bar_____') } 'App::Sqitch::X',
        'Database error should be converted to Sqitch exception';
    is $@->ident, $DBI::state, 'Ident should be SQL error state';
    like $@->message, qr/^ERROR:  /, 'The message should be the PostgreSQL error';
    like $@->previous_exception, qr/\QDBD::Pg::db do failed: /,
        'The DBI error should be in preview_exception';

    ##########################################################################
    # Test log_deploy_step().
    my $plan = $sqitch->plan;
    my $step = $plan->step_at(0);
    my ($tag) = $step->tags;
    is $step->name, 'users', 'Should have "users" step';
    ok !$pg->is_deployed_step($step), 'The step should not be deployed';
    ok $pg->log_deploy_step($step), 'Deploy "users" step';
    ok $pg->is_deployed_step($step), 'The step should now be deployed';

    is $pg->latest_step_id, $step->id, 'Should get users ID for latest step ID';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [[$step->id, 'users', [], [], $pg->actor]],
        'A record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step_id, step, tags, logged_by FROM events'
    ), [['deploy', $step->id, 'users', ['@alpha'], $pg->actor]],
        'A record should have been inserted into the events table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [
        [$tag->id, '@alpha', $step->id, $pg->actor],
    ], 'The tag should have been logged';

    ##########################################################################
    # Test log_revert_step().
    ok $pg->log_revert_step($step), 'Revert "users" step';
    ok !$pg->is_deployed_step($step), 'The step should no longer be deployed';

    is $pg->latest_step_id, undef, 'Should get undef for latest step';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [], 'The record should have been deleted from the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step_id, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users', ['@alpha'], $pg->actor],
        ['revert', $step->id, 'users', ['@alpha'], $pg->actor],
    ], 'The revert event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'And the tag record should have been remved';

    ##########################################################################
    # Test log_fail_step().
    ok $pg->log_fail_step($step), 'Fail "users" step';
    ok !$pg->is_deployed_step($step), 'The step still should not be deployed';

    is $pg->latest_step_id, undef, 'Should still get undef for latest step';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step_id, step, requires, conflicts, deployed_by FROM steps'
    ), [], 'Still should have not steps table record';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step_id, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id, 'users', ['@alpha'], $pg->actor],
        ['revert', $step->id, 'users', ['@alpha'], $pg->actor],
        ['fail',   $step->id, 'users', ['@alpha'], $pg->actor],
    ], 'The fail event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, step_id, applied_by FROM tags'
    ), [], 'Should still have no tag records';

    ##########################################################################
    # Test a step with dependencies.
    ok $pg->log_deploy_step($step),    'Deploy the step again';
    ok $pg->is_deployed_tag($tag),     'The tag again should be deployed';
    is $pg->latest_step_id, $step->id, 'Should still get users ID for latest step ID';

    ok my $step2 = $plan->step_at(1),   'Get the second step';
    ok $pg->log_deploy_step($step2),    'Deploy second step';
    is $pg->latest_step_id, $step2->id, 'Should get "widgets" ID for latest step ID';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step_id, step, requires, conflicts, deployed_by
          FROM steps
         ORDER BY deployed_at
    }), [
        [$step->id,  'users', [], [], $pg->actor],
        [$step2->id, 'widgets', ['users'], ['dr_evil'], $pg->actor],
    ], 'Should have both steps and requires/conflcits deployed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step_id, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $step->id,  'users',   ['@alpha'], $pg->actor],
        ['revert', $step->id,  'users',   ['@alpha'], $pg->actor],
        ['fail',   $step->id,  'users',   ['@alpha'], $pg->actor],
        ['deploy', $step->id,  'users',   ['@alpha'], $pg->actor],
        ['deploy', $step2->id, 'widgets', [],         $pg->actor],
    ], 'The new step deploy should have been logged';

    ##########################################################################
    # Test conflicts and requires.
    is_deeply [$pg->check_conflicts($step)], [], 'Step should have no conflicts';
    is_deeply [$pg->check_requires($step)], [], 'Step should have no missing dependencies';

    my $step3 = App::Sqitch::Plan::Step->new(
        name      => 'whatever',
        plan      => $plan,
        conflicts => ['users', 'widgets'],
        requires  => ['fred', 'barney', 'widgets'],
    );
    is_deeply [$pg->check_conflicts($step3)], [qw(users widgets)],
        'Should get back list of installed conflicting steps';
    is_deeply [$pg->check_requires($step3)], [qw(barney fred)],
        'Should get back list of missing dependencies';

    # Undeploy widgets.
    ok $pg->log_revert_step($step2), 'Revert "widgets"';

    is_deeply [$pg->check_conflicts($step3)], [qw(users)],
        'Should now see only "users" as a conflict';
    is_deeply [$pg->check_requires($step3)], [qw(barney fred widgets)],
        'Should get back list all three missing dependencies';

    ##########################################################################
    # Test deployed_step_ids() and deployed_step_ids_since().
    can_ok $pg, qw(deployed_step_ids deployed_step_ids_since);
    is_deeply [$pg->deployed_step_ids], [$step->id],
        'Should have one deployed step ID';
    is_deeply [$pg->deployed_step_ids_since($step)], [],
        'Should find none deployed since that one';

    # Add another one.
    ok $pg->log_deploy_step($step2), 'Log another step';
    is_deeply [$pg->deployed_step_ids], [$step->id, $step2->id],
        'Should have both deployed step IDs';
    is_deeply [$pg->deployed_step_ids_since($step)], [$step2->id],
        'Should find only the second after the first';
    is_deeply [$pg->deployed_step_ids_since($step2)], [],
        'Should find none after the second';

    ##########################################################################
    # Test begin_work() and finish_work().
    can_ok $pg, qw(begin_work finish_work);
    my $mock_dbh = Test::MockModule->new(ref $pg->_dbh, no_auto => 1);
    my $txn;
    $mock_dbh->mock(begin_work => sub { $txn = 1 });
    $mock_dbh->mock(commit     => sub { $txn = 0 });
    my @do;
    $mock_dbh->mock(do => sub { shift; @do = @_ });
    ok $pg->begin_work, 'Begin work';
    ok $txn, 'Should have started a transaction';
    is_deeply \@do, [
        'LOCK TABLE steps IN EXCLUSIVE MODE',
    ], 'The steps table should have been locked';
    ok $pg->finish_work, 'Finish work';
    ok !$txn, 'Should have committed a transaction';
    $mock_dbh->unmock_all;
};

done_testing;
