#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More 0.94;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny 0.12 qw(:all);
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

my $client = 'psql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $pg->client, $client, 'client should default to psql';
is $pg->sqitch_schema, 'sqitch', 'sqitch_schema default should be "sqitch"';
for my $attr (qw(username password db_name host port)) {
    is $pg->$attr, undef, "$attr default should be undef";
}

is $pg->destination, $ENV{PGDATABASE} || $ENV{PGUSER} || $sqitch->sysuser,
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

isa_ok $pg = $CLASS->new(sqitch => $sqitch), $CLASS;
ok $pg->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$pg->psql], [
    $client,
    '--set' => 'foo=baz',
    '--set' => 'whu=hi there',
    '--set' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to psql via --set';

##############################################################################
# Test other configs for the destination.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{PGDATABASE};
    local $ENV{PGUSER};
    for my $env (qw(PGDATABASE PGUSER)) {
        my $pg = $CLASS->new(sqitch => $sqitch);
        local $ENV{$env} = "\$ENV=whatever";
        is $pg->destination, "\$ENV=whatever", "Destination should read \$$env";
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $pg = $CLASS->new(sqitch => $sqitch);
    is $pg->destination, 'sysuser=whatever',
        'Destination should fall back on sysuser';

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
# Test _run(), _capture(), and _spool().
can_ok $pg, qw(_run _capture _spool);
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

my @capture;
$mock_sqitch->mock(capture => sub {
    shift;
    @capture = @_;
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

ok $pg->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to capture()';

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

ok $pg->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $pg->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $pg->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $pg->psql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $pg->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$pg->psql, '--file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $pg->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

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
    earliest_change_id
    latest_change_id
    is_deployed_tag
    is_deployed_change
    change_id_for
    change_id_for_depend
    name_for_change_id
    change_offset_from_id
    load_change
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

    is $pg->earliest_change_id, undef, 'No init, earliest change';
    is $pg->latest_change_id, undef, 'No init, no latest change';

    ok !$pg->initialized, 'Database should no longer seem initialized';
    push @cleanup, 'DROP SCHEMA __sqitchtest CASCADE';
    ok $pg->initialize, 'Initialize the database again';
    ok $pg->initialized, 'Database should be initialized again';
    is $pg->_dbh->selectcol_arrayref('SHOW search_path')->[0], '__sqitchtest',
        'The search path should be set to the new path';

    is $pg->earliest_change_id, undef, 'Still no earlist change';
    is $pg->latest_change_id, undef, 'Still no latest changes';

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

    # Try to register with a different URI.
    MOCKURI: {
        my $plan_mocker = Test::MockModule->new(ref $sqitch->plan );
        my $plan_proj = 'pg';
        my $plan_uri = 'http://example.net/';
        $plan_mocker->mock(project => sub { $plan_proj });
        $plan_mocker->mock(uri => sub { $plan_uri });
        throws_ok { $pg->register_project } 'App::Sqitch::X',
            'Should get an error for defined URI vs NULL registered URI';
        is $@->ident, 'engine', 'Defined URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
            project => 'pg',
            uri     => $plan_uri,
        ), 'Defined URI error message should be correct';

        # Try it when the registered URI is NULL.
        $plan_proj = 'groovy';
        throws_ok { $pg->register_project } 'App::Sqitch::X',
            'Should get an error for different URIs';
        is $@->ident, 'engine', 'Different URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
            project => 'groovy',
            uri     => $plan_uri,
            reg_uri => 'http://example.com/',
        ), 'Different URI error message should be correct';

        # Try with a NULL project URI.
        $plan_uri  = undef;
        throws_ok { $pg->register_project } 'App::Sqitch::X',
            'Should get an error for NULL plan URI';
        is $@->ident, 'engine', 'NULL plan URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" without URI: already exists with URI {uri}',
            project => 'groovy',
            uri     => 'http://example.com/',
        ), 'NULL plan uri error message should be correct';

        # It should succeed when the name and URI are the same.
        $plan_uri = 'http://example.com/';
        ok $pg->register_project, 'Register "groovy" again';
        is_deeply [ $pg->registered_projects ], ['groovy', 'pg'],
            'Should still have two registered projects';
        is_deeply $pg->_dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
        ), [
            ['pg', undef, $sqitch->user_name, $sqitch->user_email],
            ['groovy', 'http://example.com/', $sqitch->user_name, $sqitch->user_email],
        ], 'Both projects should still be registered';

        # Now try the same URI but a different name.
        $plan_proj = 'bob';
        throws_ok { $pg->register_project } 'App::Sqitch::X',
            'Should get error for an project with the URI';
        is $@->ident, 'engine', 'Existing URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: project "{reg_prog}" already using that URI',
            project => $plan_proj,
            uri     => $plan_uri,
            reg_proj => 'groovy',
        ), 'Exising URI error message should be correct';
    }

    ##########################################################################
    # Test log_deploy_change().
    my $plan = $sqitch->plan;
    my $change = $plan->change_at(0);
    my ($tag) = $change->tags;
    is $change->name, 'users', 'Should have "users" change';
    ok !$pg->is_deployed_change($change), 'The change should not be deployed';
    is_deeply [$pg->are_deployed_changes($change)], [],
        'The change should not be deployed';
    ok $pg->log_deploy_change($change), 'Deploy "users" change';
    ok $pg->is_deployed_change($change), 'The change should now be deployed';
    is_deeply [$pg->are_deployed_changes($change)], [$change->id],
        'The change should now be deployed';

    is $pg->earliest_change_id, $change->id, 'Should get users ID for earliest change ID';
    is $pg->earliest_change_id(1), undef, 'Should get no change offset 1 from earliest';
    is $pg->latest_change_id, $change->id, 'Should get users ID for latest change ID';
    is $pg->latest_change_id(1), undef, 'Should get no change offset 1 from latest';

    is_deeply all_changes(), [[
        $change->id, 'users', 'pg', '', $sqitch->user_name, $sqitch->user_email,
        $change->planner_name, $change->planner_email,
    ]],'A record should have been inserted into the changes table';
    is_deeply get_dependencies($change->id), [], 'Should have no dependencies';
    is_deeply [ $pg->changes_requiring_change($change) ], [],
        'Change should not be required';

    my @event_data = ([
        'deploy',
        $change->id,
        'users',
        'pg',
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
        'pg',
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
    is_deeply all( $pg->current_tags('nonesuch') ), [],
        'Should have no current chnages for nonexistent project';
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
    is_deeply all( $pg->current_tags('nonesuch') ), [],
        'Should have no current tags for nonexistent project';
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
    # Test log_new_tags().
    ok $pg->log_new_tags($change), 'Log new tags for "users" change';
    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'pg',
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should be the same';

    # Delete that tag.
    $pg->_dbh->do('DELETE FROM tags');
    is_deeply all_tags(), [], 'Should now have no tags';

    # Put it back.
    ok $pg->log_new_tags($change), 'Log new tags for "users" change again';
    is_deeply all_tags(), [[
        $tag->id,
        '@alpha',
        $change->id,
        'pg',
        'Good to go!',
        $sqitch->user_name,
        $sqitch->user_email,
        $tag->planner_name,
        $tag->planner_email,
    ]], 'The tag should be back';

    ##########################################################################
    # Test log_revert_change().
    ok $pg->log_revert_change($change), 'Revert "users" change';
    ok !$pg->is_deployed_change($change), 'The change should no longer be deployed';
    is_deeply [$pg->are_deployed_changes($change)], [],
        'The change should no longer be deployed';

    is $pg->earliest_change_id, undef, 'Should get undef for earliest change';
    is $pg->latest_change_id, undef, 'Should get undef for latest change';

    is_deeply all_changes(), [],
        'The record should have been deleted from the changes table';
    is_deeply all_tags(), [], 'And the tag record should have been removed';
    is_deeply get_dependencies($change->id), [], 'Should still have no dependencies';
    is_deeply [ $pg->changes_requiring_change($change) ], [],
        'Change should not be required';

    push @event_data, [
        'revert',
        $change->id,
        'users',
        'pg',
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
    is_deeply [$pg->are_deployed_changes($change)], [],
        'The change still should not be deployed';
    is $pg->earliest_change_id, undef, 'Should still get undef for earliest change';
    is $pg->latest_change_id, undef, 'Should still get undef for latest change';
    is_deeply all_changes(), [], 'Still should have not changes table record';
    is_deeply all_tags(), [], 'Should still have no tag records';
    is_deeply get_dependencies($change->id), [], 'Should still have no dependencies';
    is_deeply [ $pg->changes_requiring_change($change) ], [],
        'Change should not be required';

    push @event_data, [
        'fail',
        $change->id,
        'users',
        'pg',
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
    is $pg->earliest_change_id, $change->id, 'Should again get users ID for earliest change ID';
    is $pg->earliest_change_id(1), undef, 'Should still get no change offset 1 from earliest';
    is $pg->latest_change_id, $change->id, 'Should again get users ID for latest change ID';
    is $pg->latest_change_id(1), undef, 'Should still get no change offset 1 from latest';

    ok my $change2 = $plan->change_at(1),   'Get the second change';
    is_deeply [sort $pg->are_deployed_changes($change, $change2)], [$change->id],
        'Only the first change should be deployed';
    my ($req) = $change2->requires;
    ok $req->resolved_id($change->id),      'Set resolved ID in required depend';
    ok $pg->log_deploy_change($change2),    'Deploy second change';
    is $pg->earliest_change_id, $change->id, 'Should still get users ID for earliest change ID';
    is $pg->earliest_change_id(1), $change2->id,
        'Should get "widgets" offset 1 from earliest';
    is $pg->earliest_change_id(2), undef, 'Should get no change offset 2 from earliest';
    is $pg->latest_change_id, $change2->id, 'Should get "widgets" ID for latest change ID';
    is $pg->latest_change_id(1), $change->id,
        'Should get "user" offset 1 from earliest';
    is $pg->latest_change_id(2), undef, 'Should get no change offset 2 from latest';

    is_deeply all_changes(), [
        [
            $change->id,
            'users',
            'pg',
            '',
            $user2_name,
            $user2_email,
            $change->planner_name,
            $change->planner_email,
        ],
        [
            $change2->id,
            'widgets',
            'pg',
            'All in',
            $user2_name,
            $user2_email,
            $change2->planner_name,
            $change2->planner_email,
        ],
    ], 'Should have both changes and requires/conflcits deployed';
    is_deeply [sort $pg->are_deployed_changes($change, $change2)],
        [sort $change->id, $change2->id],
        'Both changes should be deployed';
    is_deeply get_dependencies($change->id), [],
        'Should still have no dependencies for "users"';
    is_deeply get_dependencies($change2->id), [
        [
            $change2->id,
            'conflict',
            'dr_evil',
            undef,
        ],
        [
            $change2->id,
            'require',
            'users',
            $change->id,
        ],
    ], 'Should have both dependencies for "widgets"';
    is_deeply [ $pg->changes_requiring_change($change) ], [{
        project   => 'pg',
        change_id => $change2->id,
        change    => 'widgets',
        asof_tag  => undef,
    }], 'Change "users" should be required by "widgets"';
    is_deeply [ $pg->changes_requiring_change($change2) ], [],
        'Change "widgets" should not be required';

    push @event_data, [
        'deploy',
        $change->id,
        'users',
        'pg',
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
        'pg',
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
            committed_at    => dt_for_tag( $tag->id ),
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
    # Test deployed_changes(), deployed_changes_since(), load_change, and
    # change_offset_from_id().
    can_ok $pg, qw(
        deployed_changes
        deployed_changes_since
        load_change
        change_offset_from_id
    );
    my $change_hash = {
        id            => $change->id,
        name          => $change->name,
        project       => $change->project,
        note          => $change->note,
        timestamp     => $change->timestamp,
        planner_name  => $change->planner_name,
        planner_email => $change->planner_email,
        tags          => ['@alpha'],
    };
    my $change2_hash = {
        id            => $change2->id,
        name          => $change2->name,
        project       => $change2->project,
        note          => $change2->note,
        timestamp     => $change2->timestamp,
        planner_name  => $change2->planner_name,
        planner_email => $change2->planner_email,
        tags          => [],
    };
    is_deeply [$pg->deployed_changes], [$change_hash, $change2_hash],
        'Should have two deployed changes';
    is_deeply [$pg->deployed_changes_since($change)], [$change2_hash],
        'Should find one deployed since the first one';
    is_deeply [$pg->deployed_changes_since($change2)], [],
        'Should find none deployed since the second one';

    is_deeply $pg->load_change($change->id), $change_hash,
        'Should load change 1';
    is_deeply $pg->load_change($change2->id), $change2_hash,
        'Should load change 2';
    is_deeply $pg->load_change('whatever'), undef,
        'load() should return undef for uknown change ID';

    is_deeply $pg->change_offset_from_id($change->id, undef), $change_hash,
        'Should load change with no offset';
    is_deeply $pg->change_offset_from_id($change2->id, 0), $change2_hash,
        'Should load change with offset 0';

    # Make sure the times are different.
    $pg->_dbh->do(q{
        UPDATE changes
           SET committed_at = committed_at + ?
         WHERE change_id = ?
    }, undef, '1s', $change2->id );

    # Now try some offsets.
    is_deeply $pg->change_offset_from_id($change->id, 1), $change2_hash,
        'Should find change with offset 1';
    is_deeply $pg->change_offset_from_id($change2->id, -1), $change_hash,
        'Should find change with offset -1';
    is_deeply $pg->change_offset_from_id($change->id, 2), undef,
        'Should find undef change with offset 2';

    # Revert change 2.
    ok $pg->log_revert_change($change2), 'Revert "widgets"';
    is_deeply [$pg->deployed_changes], [$change_hash],
        'Should now have one deployed change ID';
    is_deeply [$pg->deployed_changes_since($change)], [],
        'Should find none deployed since that one';

    # Add another one.
    ok $pg->log_deploy_change($change2), 'Log another change';
    is_deeply [$pg->deployed_changes], [$change_hash, $change2_hash],
        'Should have both deployed change IDs';
    is_deeply [$pg->deployed_changes_since($change)], [$change2_hash],
        'Should find only the second after the first';
    is_deeply [$pg->deployed_changes_since($change2)], [],
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

    # These were reverted and re-deployed, so might have new timestamps.
    $current_changes[0]->{committed_at} = dt_for_change( $change2->id );
    $current_changes[1]->{committed_at} = dt_for_change( $change->id );
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

    is $pg->earliest_change_id, $change->id, 'Earliest change should sill be "users"';
    is $pg->earliest_change_id(1), $change2->id,
        'Should still get "widgets" offset 1 from earliest';
    is $pg->earliest_change_id(2), $fred->id,
        'Should get "fred" offset 2 from earliest';
    is $pg->earliest_change_id(3), $barney->id,
        'Should get "barney" offset 3 from earliest';

    is $pg->latest_change_id, $barney->id, 'Latest change should be "barney"';
    is $pg->latest_change_id(1), $fred->id, 'Should get "fred" offset 1 from latest';
    is $pg->latest_change_id(2), $change2->id, 'Should get "widgets" offset 2 from latest';
    is $pg->latest_change_id(3), $change->id, 'Should get "users" offset 3 from latest';

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
    ok my $ext_change = $ext_plan->add(
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
    ok !grep( { $_ eq $ext_change->id } $pg->deployed_changes),
        'deployed_changes should not include external change';
    ok !grep( { $_ eq $ext_change->id } $pg->deployed_changes_since($change)),
        'deployed_changes_since should not include external change';

    is $pg->earliest_change_id, $change->id,
        'Earliest change should sill be "users"';
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
    # Test change_id_for().
    for my $spec (
        [
            'change_id only',
            { change_id => $change->id },
            $change->id,
        ],
        [
            'change only',
            { change => $change->name },
            $change->id,
        ],
        [
            'change + tag',
            { change => $change->name, tag => 'alpha' },
            $change->id,
        ],
        [
            'change@HEAD',
            { change => $change->name, tag => 'HEAD' },
            $change->id,
        ],
        [
            'tag only',
            { tag => 'alpha' },
            $change->id,
        ],
        [
            'ROOT',
            { tag => 'ROOT' },
            $change->id,
        ],
        [
            'FIRST',
            { tag => 'FIRST' },
            $change->id,
        ],
        [
            'HEAD',
            { tag => 'HEAD' },
            $barney->id,
        ],
        [
            'LAST',
            { tag => 'LAST' },
            $barney->id,
        ],
        [
            'project:ROOT',
            { tag => 'ROOT', project => 'groovy' },
            $ext_change->id,
        ],
        [
            'project:HEAD',
            { tag => 'HEAD', project => 'groovy' },
            $ext_change->id,
        ],
    ) {
        my ( $desc, $params, $exp_id ) = @{ $spec };
        is $pg->change_id_for(%{ $params }), $exp_id, "Should find id for $desc";
    }

    for my $spec (
        [
            'unkonwn id',
            { change_id => 'whatever' },
        ],
        [
            'unkonwn change',
            { change => 'whatever' },
        ],
        [
            'unkonwn tag',
            { tag => 'whatever' },
        ],
        [
            'change + unkonwn tag',
            { change => $change->name, tag => 'whatever' },
        ],
        [
            'change@ROOT',
            { change => $change->name, tag => 'ROOT' },
        ],
        [
            'change + different project',
            { change => $change->name, project => 'whatever' },
        ],
        [
            'tag + different project',
            { tag => 'alpha', project => 'whatever' },
        ],
    ) {
        my ( $desc, $params ) = @{ $spec };
        is $pg->change_id_for(%{ $params }), undef, "Should find nothing for $desc";
    }

    ##########################################################################
    # Test change_id_for_depend().
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
            is $pg->change_id_for_depend($dep), undef,
                "Internal $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $pg->log_deploy_change($change),
                "Log internal $desc change deployment";
            is $pg->change_id_for_depend($dep), $change->id,
                "Internal $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $pg->log_revert_change($change),
                "Log internal $desc change reversion";
            is $pg->change_id_for_depend($dep), undef,
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
            is $pg->change_id_for_depend($dep), undef,
                "External $desc depencency should not be satisfied";

            # Once deployed, dependency should be satisfied.
            ok $pg->log_deploy_change($change),
                "Log external $desc change deployment";

            is $pg->change_id_for_depend($dep), $change->id,
                "External $desc depencency should now be satisfied";

            # Revert it and try again.
            ok $pg->log_revert_change($change),
                "Log external $desc change reversion";
            is $pg->change_id_for_depend($dep), undef,
                "External $desc depencency should again be unsatisfied";
        }
    }

    ok my $ext_change2 = App::Sqitch::Plan::Change->new(
        plan => $ext_plan,
        name => 'outside_in',
    ), "Create another external change";
    ok $ext_change2->add_tag( my $ext_tag = App::Sqitch::Plan::Tag->new(
        plan    => $plan,
        change  => $ext_change2,
        name    => 'meta',
    ) ), 'Add tag external "meta"';

    ok $pg->log_deploy_change($ext_change2), 'Log the external change with tag';

    # Make sure name_for_change_id() works properly.
    ok $pg->_dbh->do(q{DELETE FROM tags WHERE project = 'pg'}),
        'Delete the pg project tags';
    is $pg->name_for_change_id($change2->id), 'widgets',
        'name_for_change_id() should return "widgets" for its ID';
    is $pg->name_for_change_id($ext_change2->id), 'outside_in@meta',
        'name_for_change_id() should return "outside_in@meta" for its ID';

    # Make sure current_changes and current_tags are project-scoped.
    is_deeply all( $pg->current_changes ), \@current_changes,
        'Should have only the "pg" changes from current_changes';
    is_deeply all( $pg->current_changes('groovy') ), [
        {
            change_id       => $ext_change2->id,
            change          => $ext_change2->name,
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $ext_change2->id ),
            planner_name    => $ext_change2->planner_name,
            planner_email   => $ext_change2->planner_email,
            planned_at      => $ext_change2->timestamp,
        }, {
            change_id       => $ext_change->id,
            change          => $ext_change->name,
            committer_name  => $user2_name,
            committer_email => $user2_email,
            committed_at    => dt_for_change( $ext_change->id ),
            planner_name    => $ext_change->planner_name,
            planner_email   => $ext_change->planner_email,
            planned_at      => $ext_change->timestamp,
        }
    ], 'Should get only requestd project changes from current_changes';
    is_deeply all( $pg->current_tags ), [],
        'Should no longer have "pg" project tags';
    is_deeply all( $pg->current_tags('groovy') ), [{
        tag_id          => $ext_tag->id,
        tag             => '@meta',
        committer_name  => $user2_name,
        committer_email => $user2_email,
        committed_at    => dt_for_tag( $ext_tag->id ),
        planner_name    => $ext_tag->planner_name,
        planner_email   => $ext_tag->planner_email,
        planned_at      => $ext_tag->timestamp,
    }], 'Should get groovy tags from current_chages()';

    ##########################################################################
    # Test changes with multiple and cross-project dependencies.
    ok my $hyper = $plan->add(
        name     => 'hypercritical',
        requires => ['pg:fred', 'groovy:crazyman'],
    ), 'Create change "hypercritial" in current plan';
    $_->resolved_id( $pg->change_id_for_depend($_) ) for $hyper->requires;
    ok $pg->log_deploy_change($hyper), 'Log change "hyper"';

    is_deeply [ $pg->changes_requiring_change($hyper) ], [],
        'No changes should require "hypercritical"';
    is_deeply [ $pg->changes_requiring_change($fred) ], [{
        project   => 'pg',
        change_id => $hyper->id,
        change    => $hyper->name,
        asof_tag  => undef,
    }], 'Change "hypercritical" should require "fred"';

    is_deeply [ $pg->changes_requiring_change($ext_change) ], [{
        project   => 'pg',
        change_id => $hyper->id,
        change    => $hyper->name,
        asof_tag  => undef,
    }], 'Change "hypercritical" should require "groovy:crazyman"';

    # Add another change with more depencencies.
    ok my $ext_change3 = App::Sqitch::Plan::Change->new(
        plan => $ext_plan,
        name => 'elsewise',
        requires => [
            App::Sqitch::Plan::Depend->new(
                plan    => $ext_plan,
                project => 'pg',
                change  => 'fred',
            ),
            App::Sqitch::Plan::Depend->new(
                plan    => $ext_plan,
                change  => 'crazyman',
            ),
        ]
    ), "Create a third external change";
    $_->resolved_id( $pg->change_id_for_depend($_) ) for $ext_change3->requires;
    ok $pg->log_deploy_change($ext_change3), 'Log change "elsewise"';

    # Check the dependencies again.
    is_deeply [ $pg->changes_requiring_change($fred) ], [
        {
            project   => 'pg',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        },
        {
            project   => 'groovy',
            change_id => $ext_change3->id,
            change    => $ext_change3->name,
            asof_tag  => undef,
        },
    ], 'Change "fred" should be required by changes in two projects';

    is_deeply [ $pg->changes_requiring_change($ext_change) ], [
        {
            project   => 'pg',
            change_id => $hyper->id,
            change    => $hyper->name,
            asof_tag  => undef,
        },
        {
            project   => 'groovy',
            change_id => $ext_change3->id,
            change    => $ext_change3->name,
            asof_tag  => undef,
        },
    ], 'Change "groovy:crazyman" should be required by changes in two projects';

    ##########################################################################
    # Test begin_work() and finish_work().
    can_ok $pg, qw(begin_work finish_work);
    my $mock_dbh = Test::MockModule->new(ref $pg->_dbh, no_auto => 1);
    my $txn;
    $mock_dbh->mock(begin_work => sub { $txn = 1  });
    $mock_dbh->mock(commit     => sub { $txn = 0  });
    $mock_dbh->mock(rollback   => sub { $txn = -1 });
    my @do;
    $mock_dbh->mock(do => sub { shift; @do = @_ });
    ok $pg->begin_work, 'Begin work';
    is $txn, 1, 'Should have started a transaction';
    is_deeply \@do, [
        'LOCK TABLE changes IN EXCLUSIVE MODE',
    ], 'The changes table should have been locked';
    ok $pg->finish_work, 'Finish work';
    is $txn, 0, 'Should have committed a transaction';
    ok $pg->begin_work, 'Begin work again';
    is $txn, 1, 'Should have started another transaction';
    ok $pg->rollback_work, 'Rollback work';
    is $txn, -1, 'Should have rolled back a transaction';
    $mock_dbh->unmock('do');

    ##########################################################################
    # Test _update_ids by old ID.
    my @proj_changes = ($change, $change2, $fred, $barney, $hyper);
    my @all_changes  = ($change, $change2, $fred, $barney, $ext_change, $ext_change2, $hyper, $ext_change3);
    my @proj_tags    = ($change->tags, $beta, $gamma);
    my @all_tags     = (@proj_tags, $ext_tag);

    # Let's just revert and re-deploy them all.
    ok $pg->log_revert_change($_), 'Revert "' . $_->name . '" change' for reverse @all_changes;
    ok $pg->log_deploy_change($_), 'Deploy "' . $_->name . '" change' for @all_changes;

    my $upd_change = $pg->_dbh->prepare(
        'UPDATE changes SET change_id = ? WHERE change_id = ?'
    );
    my $upd_tag = $pg->_dbh->prepare(
        'UPDATE tags SET tag_id = ? WHERE tag_id = ?'
    );

    for my $change (@proj_changes) {
        $upd_change->execute($change->old_id, $change->id);
    }
    for my $tag (@proj_tags) {
        $upd_tag->execute($tag->old_id, $tag->id);
    }

    # Mock Engine to silence the info notice.
    my $mock_engine = Test::MockModule->new('App::Sqitch::Engine');
    $mock_engine->mock(plan => $plan);
    $mock_engine->mock(_update_ids => sub { shift });

    is $pg->_update_ids, 9, 'Update IDs by old ID should return 9';

    # All of the current project changes should be updated.
    is_deeply [ map { [@{$_}[0,1]] } @{ all_changes() }],
        [ map { [ $_->id, $_->name ] } @all_changes ],
        'All of the change IDs should have been updated';

    # All of the current project tags should be updated.
    is_deeply [ map { [@{$_}[0,1]] } @{ all_tags() }],
        [ map { [ $_->id, $_->format_name ] } @all_tags ],
        'All of the tag IDs should have been updated';

    # Now reset them so they have to be found by name.
    $i = 0;
    for my $change (@proj_changes) {
        $upd_change->execute($change->old_id . $i++, $change->id);
    }
    for my $tag (@proj_tags) {
        $upd_tag->execute($tag->old_id . $i++, $tag->id);
    }

    is $pg->_update_ids, 9, 'Update IDs by name should also return 9';

    # All of the current project changes should be updated.
    is_deeply [ map { [@{$_}[0,1]] } @{ all_changes() }],
        [ map { [ $_->id, $_->name ] } @all_changes ],
        'All of the change IDs should have been updated by name';

    # All of the current project tags should be updated.
    is_deeply [ map { [@{$_}[0,1]] } @{ all_tags() }],
        [ map { [ $_->id, $_->format_name ] } @all_tags ],
        'All of the tag IDs should have been updated by name';

    # Unmock everything and call it a day.
    $mock_dbh->unmock_all;
    $mock_sqitch->unmock_all;
    $mock_engine->unmock_all;
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
        SELECT change_id, change, project, note, committer_name, committer_email,
               planner_name, planner_email
          FROM changes
         ORDER BY committed_at
    });
}

sub all_tags {
    $pg->_dbh->selectall_arrayref(q{
        SELECT tag_id, tag, change_id, project, note,
               committer_name, committer_email, planner_name, planner_email
          FROM tags
         ORDER BY committed_at
    });
}

sub all_events {
    $pg->_dbh->selectall_arrayref(q{
        SELECT event, change_id, change, project, note, requires, conflicts, tags,
               committer_name, committer_email, planner_name, planner_email
          FROM events
         ORDER BY committed_at
    });
}

sub get_dependencies {
    $pg->_dbh->selectall_arrayref(q{
        SELECT change_id, type, dependency, dependency_id
          FROM dependencies
         WHERE change_id = ?
         ORDER BY dependency
    }, undef, shift);
}

