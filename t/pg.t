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
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char'), "$CLASS->can('_ts2char')";
is $ts2char->('foo'),
    q{to_char(foo AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')},
    '_ts2char should work';

ok my $dtfunc = $CLASS->can('_dt'), "$CLASS->can('_dt')";
isa_ok my $dt = $dtfunc->(
    'year:2012:month:07:day:05:hour:15:minute:07:second:01:time_zone:UTC'
), 'App::Sqitch::DateTime', 'Return value of _dt()';
is $dt->year, 2012, 'DateTime year should be set';
is $dt->month,   7, 'DateTime month should be set';
is $dt->day,     5, 'DateTime day should be set';
is $dt->hour,   15, 'DateTime hour should be set';
is $dt->minute,  7, 'DateTime minute should be set';
is $dt->second,  1, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be set';

##############################################################################
# Can we do live tests?
can_ok $CLASS, qw(
    initialized
    initialize
    run_file
    run_handle
    log_deploy_change
    log_fail_change
    log_revert_change
    latest_change_id
    is_deployed_tag
    is_deployed_change
    check_requires
    check_conflicts
    name_for_change_id
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
        top_dir   => Path::Class::dir(qw(t pg)),
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

    is $pg->latest_change_id, undef, 'No init, no changes';

    ok !$pg->initialized, 'Database should no longer seem initialized';
    push @cleanup, 'DROP SCHEMA __sqitchtest CASCADE';
    ok $pg->initialize, 'Initialize the database again';
    ok $pg->initialized, 'Database should be initialized again';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], '__sqitchtest',
        'The search path should be set to the new path';

    is $pg->latest_change_id, undef, 'Still no changes';

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
    is $pg->current_state, undef, 'Current state should be undef';
    is_deeply all( $pg->current_changes ), [], 'Should have no current changes';
    is_deeply all( $pg->current_tags ), [], 'Should have no current tags';

    ##########################################################################
    # Test log_deploy_change().
    my $plan = $sqitch->plan;
    my $change = $plan->change_at(0);
    my ($tag) = $change->tags;
    is $change->name, 'users', 'Should have "users" change';
    ok !$pg->is_deployed_change($change), 'The change should not be deployed';
    ok $pg->log_deploy_change($change), 'Deploy "users" change';
    ok $pg->is_deployed_change($change), 'The change should now be deployed';

    is $pg->latest_change_id, $change->id, 'Should get users ID for latest change ID';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT change_id, change, requires, conflicts, deployed_by FROM changes'
    ), [[$change->id, 'users', [], [], $pg->actor]],
        'A record should have been inserted into the changes table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, change_id, change, tags, logged_by FROM events'
    ), [['deploy', $change->id, 'users', ['@alpha'], $pg->actor]],
        'A record should have been inserted into the events table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, change_id, applied_by FROM tags'
    ), [
        [$tag->id, '@alpha', $change->id, $pg->actor],
    ], 'The tag should have been logged';

    is $pg->name_for_change_id($change->id), 'users@alpha',
        'name_for_change_id() should return the change name with tag';

    ok my $state = $pg->current_state, 'Get the current state';
    isa_ok my $dt = delete $state->{deployed_at}, 'App::Sqitch::DateTime',
        'deployed_at value';
    is $dt->time_zone->name, 'UTC', 'Deployed_at TZ should be UTC';
    is_deeply $state, {
        change_id   => $change->id,
        change      => 'users',
        deployed_by => $pg->actor,
        tags        => ['@alpha'],
    }, 'The rest of the state should look right';
    is_deeply all( $pg->current_changes ), [
        {
            change_id   => $change->id,
            change      => 'users',
            deployed_by => $pg->actor,
            deployed_at => $dt,
        },
    ], 'Should have one current change';
    is_deeply all( $pg->current_tags ), [
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            applied_at => dt_for_tag( $tag->id ),
            applied_by => $pg->actor,
        },
    ], 'Should have one current tags';

    ##########################################################################
    # Test log_revert_change().
    ok $pg->log_revert_change($change), 'Revert "users" change';
    ok !$pg->is_deployed_change($change), 'The change should no longer be deployed';

    is $pg->latest_change_id, undef, 'Should get undef for latest change';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT change_id, change, requires, conflicts, deployed_by FROM changes'
    ), [], 'The record should have been deleted from the changes table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, change_id, change, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $change->id, 'users', ['@alpha'], $pg->actor],
        ['revert', $change->id, 'users', ['@alpha'], $pg->actor],
    ], 'The revert event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, change_id, applied_by FROM tags'
    ), [], 'And the tag record should have been remved';

    is $pg->name_for_change_id($change->id), undef,
        'name_for_change_id() should no longer return the change name';
    is $pg->current_state, undef, 'Current state should be undef again';
    is_deeply all( $pg->current_changes ), [],
        'Should again have no current changes';
    is_deeply all( $pg->current_tags ), [], 'Should again have no current tags';

    ##########################################################################
    # Test log_fail_change().
    ok $pg->log_fail_change($change), 'Fail "users" change';
    ok !$pg->is_deployed_change($change), 'The change still should not be deployed';

    is $pg->latest_change_id, undef, 'Should still get undef for latest change';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT change_id, change, requires, conflicts, deployed_by FROM changes'
    ), [], 'Still should have not changes table record';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, change_id, change, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $change->id, 'users', ['@alpha'], $pg->actor],
        ['revert', $change->id, 'users', ['@alpha'], $pg->actor],
        ['fail',   $change->id, 'users', ['@alpha'], $pg->actor],
    ], 'The fail event should have been logged';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, tag, change_id, applied_by FROM tags'
    ), [], 'Should still have no tag records';
    is $pg->current_state, undef, 'Current state should still be undef';
    is_deeply all( $pg->current_changes ), [], 'Should still have no current changes';
    is_deeply all( $pg->current_tags ), [], 'Should still have no current tags';

    ##########################################################################
    # Test a change with dependencies.
    ok $pg->log_deploy_change($change),    'Deploy the change again';
    ok $pg->is_deployed_tag($tag),     'The tag again should be deployed';
    is $pg->latest_change_id, $change->id, 'Should still get users ID for latest change ID';

    ok my $change2 = $plan->change_at(1),   'Get the second change';
    ok $pg->log_deploy_change($change2),    'Deploy second change';
    is $pg->latest_change_id, $change2->id, 'Should get "widgets" ID for latest change ID';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT change_id, change, requires, conflicts, deployed_by
          FROM changes
         ORDER BY deployed_at
    }), [
        [$change->id,  'users', [], [], $pg->actor],
        [$change2->id, 'widgets', ['users'], ['dr_evil'], $pg->actor],
    ], 'Should have both changes and requires/conflcits deployed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, change_id, change, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['deploy', $change->id,  'users',   ['@alpha'], $pg->actor],
        ['revert', $change->id,  'users',   ['@alpha'], $pg->actor],
        ['fail',   $change->id,  'users',   ['@alpha'], $pg->actor],
        ['deploy', $change->id,  'users',   ['@alpha'], $pg->actor],
        ['deploy', $change2->id, 'widgets', [],         $pg->actor],
    ], 'The new change deploy should have been logged';

    is $pg->name_for_change_id($change2->id), 'widgets',
        'name_for_change_id() should return just the change name';

    ok $state = $pg->current_state, 'Get the current state again';
    isa_ok $dt = delete $state->{deployed_at}, 'App::Sqitch::DateTime',
        'deployed_at value';
    is $dt->time_zone->name, 'UTC', 'Deployed_at TZ should be UTC';
    is_deeply $state, {
        change_id   => $change2->id,
        change      => 'widgets',
        deployed_by => $pg->actor,
        tags        => [],
    }, 'The state should reference new change';
    is_deeply all( $pg->current_changes ), [
        {
            change_id   => $change2->id,
            change      => 'widgets',
            deployed_by => $pg->actor,
            deployed_at => $dt,
        },
        {
            change_id   => $change->id,
            change      => 'users',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $change->id ),
        },
    ], 'Should have two current changes in reverse chronological order';
    is_deeply all( $pg->current_tags ), [
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            applied_at => dt_for_tag( $tag->id ),
            applied_by => $pg->actor,
        },
    ], 'Should again have one current tags';

    ##########################################################################
    # Test conflicts and requires.
    is_deeply [$pg->check_conflicts($change)], [], 'Change should have no conflicts';
    is_deeply [$pg->check_requires($change)], [], 'Change should have no missing dependencies';

    my $change3 = App::Sqitch::Plan::Change->new(
        name      => 'whatever',
        plan      => $plan,
        conflicts => ['users', 'widgets'],
        requires  => ['fred', 'barney', 'widgets'],
    );
    $plan->add('fred');
    $plan->add('barney');

    is_deeply [$pg->check_conflicts($change3)], [qw(users widgets)],
        'Should get back list of installed conflicting changes';
    is_deeply [$pg->check_requires($change3)], [qw(barney fred)],
        'Should get back list of missing dependencies';

    # Undeploy widgets.
    ok $pg->log_revert_change($change2), 'Revert "widgets"';

    is_deeply [$pg->check_conflicts($change3)], [qw(users)],
        'Should now see only "users" as a conflict';
    is_deeply [$pg->check_requires($change3)], [qw(barney fred widgets)],
        'Should get back list all three missing dependencies';

    ##########################################################################
    # Test deployed_change_ids() and deployed_change_ids_since().
    can_ok $pg, qw(deployed_change_ids deployed_change_ids_since);
    is_deeply [$pg->deployed_change_ids], [$change->id],
        'Should have one deployed change ID';
    is_deeply [$pg->deployed_change_ids_since($change)], [],
        'Should find none deployed since that one';

    # Add another one.
    ok $pg->log_deploy_change($change2), 'Log another change';
    is_deeply [$pg->deployed_change_ids], [$change->id, $change2->id],
        'Should have both deployed change IDs';
    is_deeply [$pg->deployed_change_ids_since($change)], [$change2->id],
        'Should find only the second after the first';
    is_deeply [$pg->deployed_change_ids_since($change2)], [],
        'Should find none after the second';

    ok $state = $pg->current_state, 'Get the current state once more';
    isa_ok $dt = delete $state->{deployed_at}, 'App::Sqitch::DateTime',
        'deployed_at value';
    is $dt->time_zone->name, 'UTC', 'Deployed_at TZ should be UTC';
    is_deeply $state, {
        change_id   => $change2->id,
        change      => 'widgets',
        deployed_by => $pg->actor,
        tags        => [],
    }, 'The new state should reference latest change';
    is_deeply all( $pg->current_changes ), [
        {
            change_id   => $change2->id,
            change      => 'widgets',
            deployed_by => $pg->actor,
            deployed_at => $dt,
        },
        {
            change_id   => $change->id,
            change      => 'users',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $change->id ),
        },
    ], 'Should still have two current changes in reverse chronological order';
    is_deeply all( $pg->current_tags ), [
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            applied_at => dt_for_tag( $tag->id ),
            applied_by => $pg->actor,
        },
    ], 'Should still have one current tags';

    ##########################################################################
    # Deploy the new changes with two tags.
    $plan->add_tag('beta');
    $plan->add_tag('gamma');
    ok my $fred = $plan->get('fred'),     'Get the "fred" change';
    ok $pg->log_deploy_change($fred),     'Deploy "fred"';
    ok my $barney = $plan->get('barney'), 'Get the "barney" change';
    ok $pg->log_deploy_change($barney),   'Deploy "barney"';

    is $pg->latest_change_id, $barney->id, 'Latest change should be "barney"';
    is_deeply $pg->current_state, {
        change_id   => $barney->id,
        change      => 'barney',
        deployed_by => $pg->actor,
        deployed_at => dt_for_change($barney->id),
        tags        => [qw(@beta @gamma)],
    }, 'Barney should be in the current state';

    is_deeply all( $pg->current_changes ), [
        {
            change_id   => $barney->id,
            change      => 'barney',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $barney->id ),
        },
        {
            change_id   => $fred->id,
            change      => 'fred',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $fred->id ),
        },
        {
            change_id   => $change2->id,
            change      => 'widgets',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $change2->id ),
        },
        {
            change_id   => $change->id,
            change      => 'users',
            deployed_by => $pg->actor,
            deployed_at => dt_for_change( $change->id ),
        },
    ], 'Should have all four current changes in reverse chron order';

    my ($beta, $gamma) = $barney->tags;
    is_deeply all( $pg->current_tags ), [
        {
            tag_id     => $gamma->id,
            tag        => '@gamma',
            applied_at => dt_for_tag( $gamma->id ),
            applied_by => $pg->actor,
        },
        {
            tag_id     => $beta->id,
            tag        => '@beta',
            applied_at => dt_for_tag( $beta->id ),
            applied_by => $pg->actor,
        },
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            applied_at => dt_for_tag( $tag->id ),
            applied_by => $pg->actor,
        },
    ], 'Should now have three current tags in reverse chron order';

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
        'LOCK TABLE changes IN EXCLUSIVE MODE',
    ], 'The changes table should have been locked';
    ok $pg->finish_work, 'Finish work';
    ok !$txn, 'Should have committed a transaction';
    $mock_dbh->unmock_all;
};

sub dt_for_change {
    my $col = $ts2char->('deployed_at');
    $dtfunc->($pg->_dbh->selectcol_arrayref(
        "SELECT $col FROM changes WHERE change_id = ?",
        undef, shift
    )->[0]);
}

sub dt_for_tag {
    my $col = $ts2char->('applied_at');
    $dtfunc->($pg->_dbh->selectcol_arrayref(
        "SELECT $col FROM tags WHERE tag_id = ?",
        undef, shift
    )->[0]);
}

sub all {
    my $iter = shift;
    my @res;
    while (my $row = $iter->()) {
        push @res => $row;
    }
    return \@res;
}

done_testing;
