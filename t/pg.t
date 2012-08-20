#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More 0.94;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Plan;

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

my $sqitch = App::Sqitch->new;
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
    db_client   => '/some/other/psql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
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
    is_satisfied_depend
    name_for_change_id
);

my @cleanup;
END {
    $pg->_dbh->do(
        "SET client_min_messages=warning; $_"
    ) for @cleanup;
}

subtest 'live database' => sub {
    my @sqitch_params = (
        db_username => 'postgres',
        top_dir     => Path::Class::dir(qw(t pg)),
        plan_file   => Path::Class::file(qw(t pg sqitch.plan)),
    );
    my $user1_name = 'Marge Simpson';
    my $user1_email = 'marge@example.com';
    $sqitch = App::Sqitch->new(
        @sqitch_params,
        user_name  => $user1_name,
        user_email => $user1_email,
    );
    $pg = $CLASS->new(sqitch => $sqitch);
    try {
        $pg->_dbh;
    } catch {
        plan skip_all => "Unable to connect to a database for testing: "
            . eval { $_->message } || $_;
    };

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
    is_deeply all( $pg->search_events ), [], 'Should have no events';

    ##############################################################################
    # Test register_project().
    can_ok $pg, 'register_project';
    can_ok $pg, 'registered_projects';

    is_deeply [ $pg->registered_projects ], [],
        'Should have no registered projects';

    ok $pg->register_project, 'Register the project';
    is_deeply [ $pg->registered_projects ], ['pg'],
        'Should have one registered project, "pg"';
    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should be registered';

    # Try to register it again.
    ok $pg->register_project, 'Register the project again';
    is_deeply [ $pg->registered_projects ], ['pg'],
        'Should still have one registered project, "pg"';
    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should still be registered only once';

    # Register a different project name.
    MOCKPROJECT: {
        my $plan_mocker = Test::MockModule->new(ref $sqitch->plan );
        $plan_mocker->mock(project => 'groovy');
        $plan_mocker->mock(uri     => 'http://example.com/');
        ok $pg->register_project, 'Register a second project';
    }

    is_deeply [ $pg->registered_projects ], ['groovy', 'pg'],
        'Should have both registered projects';
    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
    ), [
        ['pg', undef, $sqitch->user_name, $sqitch->user_email],
        ['groovy', 'http://example.com/', $sqitch->user_name, $sqitch->user_email],
    ], 'Both projects should now be registered';

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

    is_deeply all_changes(), [[
        $change->id, 'users', '', [], [], $sqitch->user_name, $sqitch->user_email,
        $change->planner_name, $change->planner_email,
    ]],'A record should have been inserted into the changes table';

    my @event_data = ([
        'deploy',
        $change->id,
        'users',
        '',
        [],
        [],
        ['@alpha'],
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ]);

    is_deeply all_events(), \@event_data,
        'A record should have been inserted into the events table';

    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should have been logged';

    is $pg->name_for_change_id($change->id), 'users@alpha',
        'name_for_change_id() should return the change name with tag';

    ok my $state = $pg->current_state, 'Get the current state';
    isa_ok my $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => ['@alpha'],
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    }, 'The rest of the state should look right';
    is_deeply all( $pg->current_changes ), [{
        change_id       => $change->id,
        change          => 'users',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => $dt,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    }], 'Should have one current change';
    is_deeply all( $pg->current_tags ), [{
        tag_id          => $tag->id,
        tag             => '@alpha',
        committed_at    => dt_for_tag( $tag->id ),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        planner_name    => $tag->planner_name,
        planner_email   => $tag->planner_email,
        planned_at      => $tag->timestamp,
    }], 'Should have one current tags';
    my @events = ({
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => ['@alpha'],
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(0),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    });
    is_deeply all( $pg->search_events ), \@events, 'Should have one event';

    ##########################################################################
    # Test log_revert_change().
    ok $pg->log_revert_change($change), 'Revert "users" change';
    ok !$pg->is_deployed_change($change), 'The change should no longer be deployed';

    is $pg->latest_change_id, undef, 'Should get undef for latest change';

    is_deeply all_changes(), [],
        'The record should have been deleted from the changes table';
    is_deeply all_tags(), [], 'And the tag record should have been removed';

    push @event_data, [
        'revert',
        $change->id,
        'users',
        '',
        [],
        [],
        ['@alpha'],
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ];

    is_deeply all_events(), \@event_data,
        'The revert event should have been logged';

    is $pg->name_for_change_id($change->id), undef,
        'name_for_change_id() should no longer return the change name';
    is $pg->current_state, undef, 'Current state should be undef again';
    is_deeply all( $pg->current_changes ), [],
        'Should again have no current changes';
    is_deeply all( $pg->current_tags ), [], 'Should again have no current tags';

    unshift @events => {
        event           => 'revert',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => ['@alpha'],
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(1),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    };
    is_deeply all( $pg->search_events ), \@events, 'Should have two events';

    ##########################################################################
    # Test log_fail_change().
    ok $pg->log_fail_change($change), 'Fail "users" change';
    ok !$pg->is_deployed_change($change), 'The change still should not be deployed';
    is $pg->latest_change_id, undef, 'Should still get undef for latest change';
    is_deeply all_changes(), [], 'Still should have not changes table record';
    is_deeply all_tags(), [], 'Should still have no tag records';

    push @event_data, [
        'fail',
        $change->id,
        'users',
        '',
        [],
        [],
        ['@alpha'],
        $sqitch->user_name,
        $sqitch->user_email,
        $change->planner_name,
        $change->planner_email
    ];

    is_deeply all_events(), \@event_data, 'The fail event should have been logged';
    is $pg->current_state, undef, 'Current state should still be undef';
    is_deeply all( $pg->current_changes ), [], 'Should still have no current changes';
    is_deeply all( $pg->current_tags ), [], 'Should still have no current tags';

    unshift @events => {
        event           => 'fail',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => ['@alpha'],
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(2),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    };
    is_deeply all( $pg->search_events ), \@events, 'Should have 3 events';

    # From here on in, use a different committer.
    my $user2_name  = 'Homer Simpson';
    my $user2_email = 'homer@example.com';
    $sqitch = App::Sqitch->new(
        @sqitch_params,
        user_name  => $user2_name,
        user_email => $user2_email,
    );
    ok $pg = $CLASS->new(
        sqitch        => $sqitch,
        sqitch_schema => '__sqitchtest',
    ), 'Create a pg with differnt user info';

    ##########################################################################
    # Test a change with dependencies.
    ok $pg->log_deploy_change($change),    'Deploy the change again';
    ok $pg->is_deployed_tag($tag),     'The tag again should be deployed';
    is $pg->latest_change_id, $change->id, 'Should still get users ID for latest change ID';

    ok my $change2 = $plan->change_at(1),   'Get the second change';
    ok $pg->log_deploy_change($change2),    'Deploy second change';
    is $pg->latest_change_id, $change2->id, 'Should get "widgets" ID for latest change ID';

    is_deeply all_changes(), [
        [
            $change->id,
            'users',
            '',
            [],
            [],
            $user2_name,
            $user2_email,
            $change->planner_name,
            $change->planner_email,
        ],
        [
            $change2->id,
            'widgets',
            'All in',
            ['users'],
            ['dr_evil'],
            $user2_name,
            $user2_email,
            $change2->planner_name,
            $change2->planner_email,
        ],
    ], 'Should have both changes and requires/conflcits deployed';

    push @event_data, [
        'deploy',
        $change->id,
        'users',
        '',
        [],
        [],
        ['@alpha'],
        $user2_name,
        $user2_email,
        $change->planner_name,
        $change->planner_email,
    ], [
        'deploy',
        $change2->id,
        'widgets',
        'All in',
        ['users'],
        ['dr_evil'],
        [],
        $user2_name,
        $user2_email,
        $change->planner_name,
        $change->planner_email,
    ];
    is_deeply all_events(), \@event_data,
        'The new change deploy should have been logged';

    is $pg->name_for_change_id($change2->id), 'widgets',
        'name_for_change_id() should return just the change name';

    ok $state = $pg->current_state, 'Get the current state again';
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
        tags            => [],
    }, 'The state should reference new change';

    my @current_changes = (
        {
            change_id       => $change2->id,
            change          => 'widgets',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $change2->id ),
            planner_name    => $change2->planner_name,
            planner_email   => $change2->planner_email,
            planned_at      => $change2->timestamp,
        },
        {
            change_id       => $change->id,
            change          => 'users',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $change->id ),
            planner_name    => $change->planner_name,
            planner_email   => $change->planner_email,
            planned_at      => $change->timestamp,
        },
    );

    is_deeply all( $pg->current_changes ), \@current_changes,
        'Should have two current changes in reverse chronological order';

    my @current_tags = (
        {
            tag_id     => $tag->id,
            tag        => '@alpha',
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at => dt_for_tag( $tag->id ),
            planner_name    => $tag->planner_name,
            planner_email   => $tag->planner_email,
            planned_at      => $tag->timestamp,
        },
    );
    is_deeply all( $pg->current_tags ), \@current_tags,
        'Should again have one current tags';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => ['users'],
        conflicts       => ['dr_evil'],
        tags            => [],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(4),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => ['@alpha'],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(3),
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    };
    is_deeply all( $pg->search_events ), \@events, 'Should have 5 events';

    ##########################################################################
    # Test deployed_change_ids() and deployed_change_ids_since().
    can_ok $pg, qw(deployed_change_ids deployed_change_ids_since);
    is_deeply [$pg->deployed_change_ids], [$change->id, $change2->id],
        'Should have two deployed change ID';
    is_deeply [$pg->deployed_change_ids_since($change)], [$change2->id],
        'Should find one deployed since the first one';
    is_deeply [$pg->deployed_change_ids_since($change2)], [],
        'Should find none deployed since the second one';

    # Revert change 2.
    ok $pg->log_revert_change($change2), 'Revert "widgets"';
    is_deeply [$pg->deployed_change_ids], [$change->id],
        'Should now have one deployed change ID';
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
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'committed_at value';
    is $dt->time_zone->name, 'UTC', 'committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => [],
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, 'The new state should reference latest change';
    is_deeply all( $pg->current_changes ), \@current_changes,
        'Should still have two current changes in reverse chronological order';
    is_deeply all( $pg->current_tags ), \@current_tags,
        'Should still have one current tags';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => ['users'],
        conflicts       => ['dr_evil'],
        tags            => [],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(6),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    }, {
        event           => 'revert',
        project         => 'pg',
        change_id       => $change2->id,
        change          => 'widgets',
        note            => 'All in',
        requires        => ['users'],
        conflicts       => ['dr_evil'],
        tags            => [],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(5),
        planner_name    => $change2->planner_name,
        planner_email   => $change2->planner_email,
        planned_at      => $change2->timestamp,
    };
    is_deeply all( $pg->search_events ), \@events, 'Should have 7 events';

    ##########################################################################
    # Deploy the new changes with two tags.
    $plan->add( name => 'fred' );
    $plan->add( name => 'barney' );
    $plan->tag( name => 'beta' );
    $plan->tag( name => 'gamma' );
    ok my $fred = $plan->get('fred'),     'Get the "fred" change';
    ok $pg->log_deploy_change($fred),     'Deploy "fred"';
    ok my $barney = $plan->get('barney'), 'Get the "barney" change';
    ok $pg->log_deploy_change($barney),   'Deploy "barney"';

    is $pg->latest_change_id, $barney->id, 'Latest change should be "barney"';
    is_deeply $pg->current_state, {
        project         => 'pg',
        change_id       => $barney->id,
        change          => 'barney',
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_change($barney->id),
        tags            => [qw(@beta @gamma)],
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, 'Barney should be in the current state';

    unshift @current_changes => {
        change_id       => $barney->id,
        change          => 'barney',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_change( $barney->id ),
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, {
        change_id       => $fred->id,
        change          => 'fred',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_change( $fred->id ),
        planner_name    => $fred->planner_name,
        planner_email   => $fred->planner_email,
        planned_at      => $fred->timestamp,
    };

    is_deeply all( $pg->current_changes ), \@current_changes,
        'Should have all four current changes in reverse chron order';

    my ($beta, $gamma) = $barney->tags;

    unshift @current_tags => {
        tag_id          => $gamma->id,
        tag             => '@gamma',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $gamma->id ),
        planner_name    => $gamma->planner_name,
        planner_email   => $gamma->planner_email,
        planned_at      => $gamma->timestamp,
    }, {
        tag_id          => $beta->id,
        tag             => '@beta',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $beta->id ),
        planner_name    => $beta->planner_name,
        planner_email   => $beta->planner_email,
        planned_at      => $beta->timestamp,
    };

    is_deeply all( $pg->current_tags ), \@current_tags,
        'Should now have three current tags in reverse chron order';

    unshift @events => {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $barney->id,
        change          => 'barney',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => ['@beta', '@gamma'],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(8),
        planner_name    => $barney->planner_name,
        planner_email   => $barney->planner_email,
        planned_at      => $barney->timestamp,
    }, {
        event           => 'deploy',
        project         => 'pg',
        change_id       => $fred->id,
        change          => 'fred',
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => [],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(7),
        planner_name    => $fred->planner_name,
        planner_email   => $fred->planner_email,
        planned_at      => $fred->timestamp,
    };
    is_deeply all( $pg->search_events ), \@events, 'Should have 9 events';

    ##########################################################################
    # Test search_events() parameters.
    is_deeply all( $pg->search_events(limit => 2) ), [ @events[0..1] ],
        'The limit param to search_events should work';

    is_deeply all( $pg->search_events(offset => 4) ), [ @events[4..$#events] ],
        'The offset param to search_events should work';

    is_deeply all( $pg->search_events(limit => 3, offset => 4) ), [ @events[4..6] ],
        'The limit and offset params to search_events should work together';

    is_deeply all( $pg->search_events( direction => 'DESC' ) ), \@events,
        'Should work to set direction "DESC" in search_events';
    is_deeply all( $pg->search_events( direction => 'desc' ) ), \@events,
        'Should work to set direction "desc" in search_events';
    is_deeply all( $pg->search_events( direction => 'descending' ) ), \@events,
        'Should work to set direction "descending" in search_events';

    is_deeply all( $pg->search_events( direction => 'ASC' ) ),
        [ reverse @events ],
        'Should work to set direction "ASC" in search_events';
    is_deeply all( $pg->search_events( direction => 'asc' ) ),
        [ reverse @events ],
        'Should work to set direction "asc" in search_events';
    is_deeply all( $pg->search_events( direction => 'ascending' ) ),
        [ reverse @events ],
        'Should work to set direction "ascending" in search_events';
    throws_ok { $pg->search_events( direction => 'foo' ) } 'App::Sqitch::X',
        'Should catch exception for invalid search direction';
    is $@->ident, 'DEV', 'Search direction error ident should be "DEV"';
    is $@->message, 'Search direction must be either "ASC" or "DESC"',
        'Search direction error message should be correct';

    is_deeply all( $pg->search_events( committer => 'Simpson$' ) ), \@events,
        'The committer param to search_events should work';
    is_deeply all( $pg->search_events( committer => "^Homer" ) ),
        [ @events[0..5] ],
        'The committer param to search_events should work as a regex';
    is_deeply all( $pg->search_events( committer => 'Simpsonized$' ) ), [],
        qq{Committer regex should fail to match with "Simpsonized\$"};

    is_deeply all( $pg->search_events( change => 'users' ) ),
        [ @events[5..$#events] ],
        'The change param to search_events should work with "users"';
    is_deeply all( $pg->search_events( change => 'widgets' ) ),
        [ @events[2..4] ],
        'The change param to search_events should work with "widgets"';
    is_deeply all( $pg->search_events( change => 'fred' ) ),
        [ $events[1] ],
        'The change param to search_events should work with "fred"';
    is_deeply all( $pg->search_events( change => 'fre$' ) ), [],
        'The change param to search_events should return nothing for "fre$"';
    is_deeply all( $pg->search_events( change => '(er|re)' ) ),
        [@events[1, 5..8]],
        'The change param to search_events should return match "(er|re)"';

    is_deeply all( $pg->search_events( event => [qw(deploy)] ) ),
        [ grep { $_->{event} eq 'deploy' } @events ],
        'The event param should work with "deploy"';
    is_deeply all( $pg->search_events( event => [qw(revert)] ) ),
        [ grep { $_->{event} eq 'revert' } @events ],
        'The event param should work with "revert"';
    is_deeply all( $pg->search_events( event => [qw(fail)] ) ),
        [ grep { $_->{event} eq 'fail' } @events ],
        'The event param should work with "fail"';
    is_deeply all( $pg->search_events( event => [qw(revert fail)] ) ),
        [ grep { $_->{event} ne 'deploy' } @events ],
        'The event param should work with "revert" and "fail"';
    is_deeply all( $pg->search_events( event => [qw(deploy revert fail)] ) ),
        \@events,
        'The event param should work with "deploy", "revert", and "fail"';
    is_deeply all( $pg->search_events( event => ['foo'] ) ), [],
        'The event param should return nothing for "foo"';

    # Add an external project event.
    ok my $ext_plan = App::Sqitch::Plan->new(
        sqitch => $sqitch,
        project => 'groovy',
    ), 'Create external plan';
    ok my $ext_change = App::Sqitch::Plan::Change->new(
        plan => $ext_plan,
        name => 'crazyman',
    ), "Create external change";
    ok $pg->log_deploy_change($ext_change), 'Log the external change';
    my $ext_event = {
        event           => 'deploy',
        project         => 'groovy',
        change_id       => $ext_change->id,
        change          => $ext_change->name,
        note            => '',
        requires        => [],
        conflicts       => [],
        tags            => [],
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_event(9),
        planner_name    => $user2_name,
        planner_email   => $user2_email,
        planned_at      => $ext_change->timestamp,
    };
    is_deeply all( $pg->search_events( project => '^pg$' ) ), \@events,
        'The project param to search_events should work';
    is_deeply all( $pg->search_events( project => '^groovy$' ) ), [$ext_event],
        'The project param to search_events should work with external project';
    is_deeply all( $pg->search_events( project => 'g' ) ), [$ext_event, @events],
        'The project param to search_events should match across projects';
    is_deeply all( $pg->search_events( project => 'nonexistent' ) ), [],
        qq{Project regex should fail to match with "nonexistent"};

    # Make sure we do not see these changes where we should not.
    ok !grep( { $_ eq $ext_change->id } $pg->deployed_change_ids),
        'deployed_change_ids should not include external change';
    ok !grep( { $_ eq $ext_change->id } $pg->deployed_change_ids_since($change)),
        'deployed_change_ids_since should not include external change';

    isnt $pg->latest_change_id, $ext_change->id,
        'Latest change ID should not be from external project';

    throws_ok { $pg->search_events(foo => 1) } 'App::Sqitch::X',
        'Should catch exception for invalid search param';
    is $@->ident, 'DEV', 'Invalid search param error ident should be "DEV"';
    is $@->message, 'Invalid parameters passed to search_events(): foo',
        'Invalid search param error message should be correct';

    throws_ok { $pg->search_events(foo => 1, bar => 2) } 'App::Sqitch::X',
        'Should catch exception for invalid search params';
    is $@->ident, 'DEV', 'Invalid search params error ident should be "DEV"';
    is $@->message, 'Invalid parameters passed to search_events(): bar, foo',
        'Invalid search params error message should be correct';

    ##########################################################################
    # Now that we have a change from an externa project, get its state.
    ok $state = $pg->current_state('groovy'), 'Get the "groovy" state';
    isa_ok $dt = delete $state->{committed_at}, 'App::Sqitch::DateTime',
        'groofy committed_at value';
    is $dt->time_zone->name, 'UTC', 'groovy committed_at TZ should be UTC';
    is_deeply $state, {
        project         => 'groovy',
        change_id       => $ext_change->id,
        change          => $ext_change->name,
        note            => '',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        tags            => [],
        planner_name    => $ext_change->planner_name,
        planner_email   => $ext_change->planner_email,
        planned_at      => $ext_change->timestamp,
    }, 'The rest of the state should look right';

    ##########################################################################
    # Test is_satisfied_depend.
    my $id = '4f1e83f409f5f533eeef9d16b8a59e2c0aa91cc1';
    my $i;

    for my $spec (
        [
            'id only',
            { id => $id },
            { id => $id },
        ],
        [
            'change + tag',
            { change => 'bart', tag => 'epsilon' },
            { name   => 'bart' }
        ],
        [
            'change only',
            { change => 'lisa' },
            { name   => 'lisa' },
        ],
        [
            'tag only',
            { tag  => 'sigma' },
            { name => 'maggie' },
        ],
    ) {
        my ( $desc, $dep_params, $chg_params ) = @{ $spec };

        # Test as an internal dependency.
        INTERNAL: {
            ok my $change = $plan->add(
                name    => 'foo' . ++$i,
                %{$chg_params},
            ), "Create internal $desc change";

            # Tag it if necessary.
            if (my $tag = $dep_params->{tag}) {
                ok $plan->tag(name => $tag), "Add tag internal \@$tag";
            }

            # Should start with unsatisfied dependency.
            ok my $dep = App::Sqitch::Plan::Depend->new(
                plan    => $plan,
                project => $plan->project,
                %{ $dep_params },
            ), "Create internal $desc dependency";
            ok !$pg->is_satisfied_depend($dep),
                "Internal $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $pg->log_deploy_change($change),
                "Log internal $desc change deployment";
            ok $pg->is_satisfied_depend($dep),
                "Internal $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $pg->log_revert_change($change),
                "Log internal $desc change reversion";
            ok !$pg->is_satisfied_depend($dep),
                "Internal $desc depencency should again be unsatisfied";
        }

        # Now test as an external dependency.
        EXTERNAL: {
            # Make Change and Tag return registered external project "groovy".
            $dep_params->{project} = 'groovy';
            my $line_mocker = Test::MockModule->new('App::Sqitch::Plan::Line');
            $line_mocker->mock(project => $dep_params->{project});

            ok my $change = App::Sqitch::Plan::Change->new(
                plan    => $plan,
                name    => 'foo' . ++$i,
                %{$chg_params},
            ), "Create external $desc change";

            # Tag it if necessary.
            if (my $tag = $dep_params->{tag}) {
                ok $change->add_tag(App::Sqitch::Plan::Tag->new(
                    plan    => $plan,
                    change  => $change,
                    name    => $tag,
                ) ), "Add tag external \@$tag";
            }

            # Should start with unsatisfied dependency.
            ok my $dep = App::Sqitch::Plan::Depend->new(
                plan    => $plan,
                project => $plan->project,
                %{ $dep_params },
            ), "Create external $desc dependency";
            ok !$pg->is_satisfied_depend($dep),
                "External $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $pg->log_deploy_change($change),
                "Log external $desc change deployment";

            ok $pg->is_satisfied_depend($dep),
                "External $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $pg->log_revert_change($change),
                "Log external $desc change reversion";
            ok !$pg->is_satisfied_depend($dep),
                "External $desc depencency should again be unsatisfied";
        }
    }

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
    done_testing;
};

done_testing;

sub dt_for_change {
    my $col = $ts2char->('committed_at');
    $dtfunc->($pg->_dbh->selectcol_arrayref(
        "SELECT $col FROM changes WHERE change_id = ?",
        undef, shift
    )->[0]);
}

sub dt_for_tag {
    my $col = $ts2char->('committed_at');
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

sub dt_for_event {
    my $col = $ts2char->('committed_at');
    $dtfunc->($pg->_dbh->selectcol_arrayref(
        "SELECT $col FROM events ORDER BY committed_at ASC OFFSET ? LIMIT 1",
        undef, shift
    )->[0]);
}

sub all_changes {
    $pg->_dbh->selectall_arrayref(q{
        SELECT change_id, change, note, requires, conflicts,
               committer_name, committer_email, planner_name, planner_email
          FROM changes
         ORDER BY committed_at
    });
}

sub all_tags {
    $pg->_dbh->selectall_arrayref(q{
        SELECT tag_id, tag, change_id, note,
               committer_name, committer_email, planner_name, planner_email
          FROM tags
         ORDER BY committed_at
    });
}

sub all_events {
    $pg->_dbh->selectall_arrayref(q{
        SELECT event, change_id, change, note, requires, conflicts, tags,
               committer_name, committer_email, planner_name, planner_email
          FROM events
         ORDER BY committed_at
    });
}

