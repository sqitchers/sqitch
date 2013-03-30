#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Test::MockModule;
use Path::Class;
use Try::Tiny;
use Test::Exception;
use DBI;
use Locale::TextDomain qw(App-Sqitch);

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::sqlite';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
}

is_deeply [$CLASS->config_vars], [
    client    => 'any',
    db_name   => 'any',
    sqitch_db => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch, db_name => file 'foo'), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'MSWin32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->db_name, 'foo', 'db_name should be required';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be db_name strintified';
is $sqlite->sqitch_db, file('foo')->dir->file('sqitch.db'),
    'sqitch_db should default to "sqitch.db" in the same diretory as db_name';

my @std_opts = (
    '-noheader',
    '-bail',
    '-csv',
);

is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have the proper opts';

##############################################################################
# Make sure we get an error for no database name.
isa_ok $sqlite = $CLASS->new(sqitch => $sqitch), $CLASS;
throws_ok { $sqlite->_dbh } 'App::Sqitch::X', 'Should get an error for no db name';
is $@->ident, 'sqlite', 'Missing db name error ident should be "sqlite"';
is $@->message, __ 'No database specified; use --db-name set "ore.sqlite.db_name" via sqitch config',
    'Missing db name error message should be correct';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.sqlite.client'    => '/path/to/sqlite3',
    'core.sqlite.db_name'   => '/path/to/sqlite.db',
    'core.sqlite.sqitch_db' => 'meta.db',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->client, '/path/to/sqlite3',
    'client should fall back on config';
is $sqlite->db_name, '/path/to/sqlite.db',
    'db_name should fall back on config';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be configured db_name strintified';
is $sqlite->sqitch_db, file('meta.db'),
    'sqitch_db should fall back on config';
is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have config values';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(db_client => 'foo/bar', db_name => 'my.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create sqlite with sqitch with --client and --db-name';
is $sqlite->client, 'foo/bar', 'The client should be grabbed from sqitch';
is $sqlite->db_name, 'my.db', 'The db_name should be grabbed from sqitch';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be optioned db_name strintified';
is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->db_name],
    'sqlite3 command should have option values';

##############################################################################
# Test _run(), _capture(), and _spool().
my $tmp_dir = Path::Class::tempdir( CLEANUP => 1 );
my $db_name = $tmp_dir->file('sqitch.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch, db_name => $db_name),
    'Instantiate with a temporary database file';

can_ok $sqlite, qw(_run _capture _spool);

my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, @capture, @spool);
$mock_sqitch->mock(run     => sub { shift; @run = @_ });
$mock_sqitch->mock(capture => sub { shift; @capture = @_ });
$mock_sqitch->mock(spool   => sub { shift; @spool = @_ });

ok $sqlite->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$sqlite->sqlite3, qw(foo bar baz)],
    'Command should be passed to run()';

ok $sqlite->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $sqlite->sqlite3],
    'Command should be passed to spool()';

ok $sqlite->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$sqlite->sqlite3, qw(foo bar baz)],
    'Command should be passed to capture()';

# Test file and handle running.
ok $sqlite->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
    'File should be passed to run()';

ok $sqlite->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $sqlite->sqlite3],
    'Handle should be passed to spool()';

QUOTE: {
    try {
        require DBD::SQLite;
    } catch {
        skip 'DBD::SQLite not installed', 2;
    };

    # Verify should go to capture unless verosity is > 1.
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
    is_deeply \@capture, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
        'Verify file should be passed to capture()';

    $mock_sqitch->mock(verbosity => 2);
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
    is_deeply \@run, [$sqlite->sqlite3, ".read 'foo/bar.sql'"],
        'Verifile file should be passed to run() for high verbosity';
}

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char';
is $CLASS->_ts2char('foo'),
    q{strftime('year:%Y:month:%m:day:%d:hour:%H:minute:%M:second:%S:time_zone:UTC', foo)},
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

subtest 'live database' => sub {
    my @sqitch_params = (
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
    $sqlite = $CLASS->new(sqitch => $sqitch, db_name => $db_name);
    try {
        $sqlite->_dbh;
    } catch {
        plan skip_all => "Unable to connect to a database for testing: "
            . eval { $_->message } || $_;
    };

    isa_ok $sqlite, $CLASS, 'The live DB engine';

    ok !$sqlite->initialized, 'Database should not yet be initialized';
    ok $sqlite->initialize, 'Initialize the database';
    ok $sqlite->initialized, 'Database should now be initialized';

    # Try it with a different Sqitch DB.
    ok $sqlite = $CLASS->new(
        sqitch    => $sqitch,
        db_name   => $db_name,
        sqitch_db => $db_name->dir->file('sqitchtest.db')
    ), 'Create a sqlite with sqitchtest.db sqitch_db';

    is $sqlite->earliest_change_id, undef, 'No init, earliest change';
    is $sqlite->latest_change_id, undef, 'No init, no latest change';

    ok !$sqlite->initialized, 'Database should no longer seem initialized';
    ok $sqlite->initialize, 'Initialize the database again';
    ok $sqlite->initialized, 'Database should be initialized again';

    is $sqlite->earliest_change_id, undef, 'Still no earlist change';
    is $sqlite->latest_change_id, undef, 'Still no latest changes';

    # Make sure a second attempt to initialize dies.
    throws_ok { $sqlite->initialize } 'App::Sqitch::X',
        'Should die on existing schema';
    is $@->ident, 'sqlite', 'Mode should be "sqlite"';
    is $@->message, __x(
        'Sqitch database {database} already initialized',
        database => $sqlite->sqitch_db,
    ), 'And it should show the proper schema in the error message';

    throws_ok { $sqlite->_dbh->do('INSERT blah INTO __bar_____') } 'App::Sqitch::X',
        'Database error should be converted to Sqitch exception';
    is $@->ident, $DBI::state, 'Ident should be SQL error state';
    is $@->message, 'near "blah": syntax error', 'The message should be the SQLite error';
    like $@->previous_exception, qr/\QDBD::SQLite::db do failed: /,
        'The DBI error should be in preview_exception';

    is $sqlite->current_state, undef, 'Current state should be undef';
    is_deeply all( $sqlite->current_changes ), [], 'Should have no current changes';
    is_deeply all( $sqlite->current_tags ), [], 'Should have no current tags';
    is_deeply all( $sqlite->search_events ), [], 'Should have no events';

    ##############################################################################
    # Test register_project().
    can_ok $sqlite, 'register_project';
    can_ok $sqlite, 'registered_projects';

    is_deeply [ $sqlite->registered_projects ], [],
        'Should have no registered projects';

    ok $sqlite->register_project, 'Register the project';
    is_deeply [ $sqlite->registered_projects ], ['pg'],
        'Should have one registered project, "sql"';
    is_deeply $sqlite->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should be registered';

    # Try to register it again.
    ok $sqlite->register_project, 'Register the project again';
    is_deeply [ $sqlite->registered_projects ], ['pg'],
        'Should still have one registered project, "sql"';
    is_deeply $sqlite->_dbh->selectall_arrayref(
        'SELECT project, uri, creator_name, creator_email FROM projects'
    ), [['pg', undef, $sqitch->user_name, $sqitch->user_email]],
        'The project should still be registered only once';

    # Register a different project name.
    MOCKPROJECT: {
        my $plan_mocker = Test::MockModule->new(ref $sqitch->plan );
        $plan_mocker->mock(project => 'groovy');
        $plan_mocker->mock(uri     => 'http://example.com/');
        ok $sqlite->register_project, 'Register a second project';
    }

    is_deeply [ $sqlite->registered_projects ], ['groovy', 'pg'],
        'Should have both registered projects';
    is_deeply $sqlite->_dbh->selectall_arrayref(
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
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get an error for defined URI vs NULL registered URI';
        is $@->ident, 'engine', 'Defined URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
            project => 'pg',
            uri     => $plan_uri,
        ), 'Defined URI error message should be correct';

        # Try it when the registered URI is NULL.
        $plan_proj = 'groovy';
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
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
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
            'Should get an error for NULL plan URI';
        is $@->ident, 'engine', 'NULL plan URI error ident should be "engine"';
        is $@->message, __x(
            'Cannot register "{project}" without URI: already exists with URI {uri}',
            project => 'groovy',
            uri     => 'http://example.com/',
        ), 'NULL plan uri error message should be correct';

        # It should succeed when the name and URI are the same.
        $plan_uri = 'http://example.com/';
        ok $sqlite->register_project, 'Register "groovy" again';
        is_deeply [ $sqlite->registered_projects ], ['groovy', 'pg'],
            'Should still have two registered projects';
        is_deeply $sqlite->_dbh->selectall_arrayref(
            'SELECT project, uri, creator_name, creator_email FROM projects ORDER BY created_at'
        ), [
            ['pg', undef, $sqitch->user_name, $sqitch->user_email],
            ['groovy', 'http://example.com/', $sqitch->user_name, $sqitch->user_email],
        ], 'Both projects should still be registered';

        # Now try the same URI but a different name.
        $plan_proj = 'bob';
        throws_ok { $sqlite->register_project } 'App::Sqitch::X',
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
    ok !$sqlite->is_deployed_change($change), 'The change should not be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [],
        'The change should not be deployed';
    ok $sqlite->log_deploy_change($change), 'Deploy "users" change';
    ok $sqlite->is_deployed_change($change), 'The change should now be deployed';
    is_deeply [$sqlite->are_deployed_changes($change)], [$change->id],
        'The change should now be deployed';

    is $sqlite->earliest_change_id, $change->id, 'Should get users ID for earliest change ID';
    is $sqlite->earliest_change_id(1), undef, 'Should get no change offset 1 from earliest';
    is $sqlite->latest_change_id, $change->id, 'Should get users ID for latest change ID';
    is $sqlite->latest_change_id(1), undef, 'Should get no change offset 1 from latest';

    is_deeply all_changes(), [[
        $change->id, 'users', 'pg', '', $sqitch->user_name, $sqitch->user_email,
        $change->planner_name, $change->planner_email,
    ]],'A record should have been inserted into the changes table';
    is_deeply get_dependencies($change->id), [], 'Should have no dependencies';
    is_deeply [ $sqlite->changes_requiring_change($change) ], [],
        'Change should not be required';


    my @event_data = ([
        'deploy',
        $change->id,
        'users',
        'pg',
        '',
        $sqlite->_log_requires_param($change),
        $sqlite->_log_conflicts_param($change),
        $sqlite->_log_tags_param($change),
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

    is $sqlite->name_for_change_id($change->id), 'users@alpha',
        'name_for_change_id() should return the change name with tag';

    ok my $state = $sqlite->current_state, 'Get the current state';
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
    is_deeply all( $sqlite->current_changes ), [{
        change_id       => $change->id,
        change          => 'users',
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => $dt,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
        planned_at      => $change->timestamp,
    }], 'Should have one current change';
    is_deeply all( $sqlite->current_tags('nonesuch') ), [],
        'Should have no current chnages for nonexistent project';
    is_deeply all( $sqlite->current_tags ), [{
        tag_id          => $tag->id,
        tag             => '@alpha',
        committed_at    => dt_for_tag( $tag->id ),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        planner_name    => $tag->planner_name,
        planner_email   => $tag->planner_email,
        planned_at      => $tag->timestamp,
    }], 'Should have one current tags';
    is_deeply all( $sqlite->current_tags('nonesuch') ), [],
        'Should have no current tags for nonexistent project';
    my @events = ({
        event           => 'deploy',
        project         => 'pg',
        change_id       => $change->id,
        change          => 'users',
        note            => '',
        requires        => $sqlite->_log_requires_param($change),
        conflicts       => $sqlite->_log_conflicts_param($change),
        tags            => $sqlite->_log_tags_param($change),
        committer_name  => $sqitch->user_name,
        committer_email => $sqitch->user_email,
        committed_at    => dt_for_event(0),
        planned_at      => $change->timestamp,
        planner_name    => $change->planner_name,
        planner_email   => $change->planner_email,
    });
    is_deeply all( $sqlite->search_events ), \@events, 'Should have one event';

    ##########################################################################
    # Test log_new_tags().
    ok $sqlite->log_new_tags($change), 'Log new tags for "users" change';
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
    $sqlite->_dbh->do('DELETE FROM tags');
    is_deeply all_tags(), [], 'Should now have no tags';

    # Put it back.
    ok $sqlite->log_new_tags($change), 'Log new tags for "users" change again';
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

};

done_testing;

sub dt_for_change {
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
        "SELECT $col FROM changes WHERE change_id = ?",
        undef, shift
    )->[0]);
}

sub dt_for_tag {
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
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
    my $col = $sqlite->_ts2char('committed_at');
    $dtfunc->($sqlite->_dbh->selectcol_arrayref(
        "SELECT $col FROM events ORDER BY committed_at ASC LIMIT 1 OFFSET ?",
        undef, shift
    )->[0]);
}

sub all_changes {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT change_id, change, project, note, committer_name, committer_email,
               planner_name, planner_email
          FROM changes
         ORDER BY committed_at
    });
}

sub all_tags {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT tag_id, tag, change_id, project, note,
               committer_name, committer_email, planner_name, planner_email
          FROM tags
         ORDER BY committed_at
    });
}

sub all_events {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT event, change_id, change, project, note, requires, conflicts, tags,
               committer_name, committer_email, planner_name, planner_email
          FROM events
         ORDER BY committed_at
    });
}

sub get_dependencies {
    $sqlite->_dbh->selectall_arrayref(q{
        SELECT change_id, type, dependency, dependency_id
          FROM dependencies
         WHERE change_id = ?
         ORDER BY dependency
    }, undef, shift);
}

