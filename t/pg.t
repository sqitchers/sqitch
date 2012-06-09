#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More;
use Test::MockModule;
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
    'client'        => '/some/other/psql',
    'username'      => 'anna',
    'db_name'       => 'widgets_dev',
    'host'          => 'foo.com',
    'port'          => 98760,
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
    log_revert_step
    is_deployed_tag
    is_deployed_step
    deployed_steps_for
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
    $sqitch = App::Sqitch->new('username' => 'postgres');
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

    return; # Pick up from here.

    # Try it with a different schema name.
    ok $pg = $CLASS->new(
        sqitch => $sqitch,
        sqitch_schema => '__sqitchtest',
    ), 'Create a pg with postgres user and __sqitchtest schema';

    is $pg->current_tag_name, undef, 'No init, no current tag';

    ok !$pg->initialized, 'Database should no longer seem initialized';
    push @cleanup, 'DROP SCHEMA __sqitchtest CASCADE';
    ok $pg->initialize, 'Initialize the database again';
    ok $pg->initialized, 'Database should be initialized again';

    # Test begin_deploy_tag() and commit_deploy_tag().
    my $sqitch = App::Sqitch->new( sql_dir => Path::Class::dir(qw(t pg)) );
    my $plan   = App::Sqitch::Plan->new( sqitch => $sqitch );
    my $tag    = App::Sqitch::Plan::Tag->new(
        names => ['alpha'],
        plan  => $plan,
    );

    is $pg->current_tag_name, undef, 'Should have no current tag';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'Should be no deployed steps';
    ok !$pg->is_deployed_tag($tag), 'The "alpha" tag should not be deployed';

    ok $pg->begin_deploy_tag($tag), 'Begin deploying "alpha" tag';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha" tag';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'Still should be no deployed steps';
    is $pg->current_tag_name, 'alpha', 'Should get "alpha" as current tag';
    ok $pg->is_deployed_tag($tag), 'The "alpha" tag should now be deployed';

    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [1, $pg->actor],
        'A record should have been inserted into the tags table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [['alpha', 1]],
        'A record should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step, tag_id, deployed_by, requires, conflicts FROM steps'
    ), [], 'No record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events'
    ), [['apply', '', ['alpha'], $pg->actor]],
        'The tag application should have been logged';

    # Now revert it.
    ok $pg->begin_revert_tag($tag), 'Begin reverting "alpha" tag';
    ok $pg->commit_revert_tag($tag), 'Commit "alpha" reversion';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'Still should be no deployed steps';
    is $pg->current_tag_name, undef, 'Should again have no current tag';
    ok !$pg->is_deployed_tag($tag), 'The "alpha" tag should again not be deployed';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
    ], 'The tag removal should have been logged';

    # Let's have a couple of tag names.
    $tag = App::Sqitch::Plan::Tag->new(
        names => [qw(alpha beta)],
        plan  => $plan,
    );

    ok $pg->begin_deploy_tag($tag), 'Begin deploying "alpha" tag again';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha"/"beta" tag';
    ok $pg->is_deployed_tag($tag), 'The "alpha" tag should again be deployed';

    is_deeply [$pg->deployed_steps_for($tag)], [],
        'Still should be no deployed steps';
    like $pg->current_tag_name, qr/^(?:alpha|beta)$/,
        'Should have "alpha" or "beta" as current tag name';

    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [2, $pg->actor],
        'A record should have been inserted into the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 2], ['beta', 2]],
        'Both names should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
    ], 'The new tag deploy should have been logged';

    # Now revert it.
    ok $pg->begin_revert_tag($tag), 'Begin reverting "alpha"/"beta" tag';
    ok $pg->commit_revert_tag($tag), 'Commit "alpha"/"beta" reversion';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'Still should be no deployed steps';
    is $pg->current_tag_name, undef, 'Should again have no current tag';
    ok !$pg->is_deployed_tag($tag), 'The "alpha" tag should again not be deployed';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too, again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
    ], 'The new tag revert should also have been logged';

    ##########################################################################
    # Now let's deploy a step, too.
    my $step = App::Sqitch::Plan::Step->new(
        name => 'users',
        tag  => $tag,
    );

    ok !$pg->is_deployed_step($step), 'The "users" step should not be deployed';
    ok $pg->begin_deploy_tag($tag), 'Begin deploying "alpha" tag with "users" step';
    push @cleanup, 'DROP SCHEMA IF EXISTS __myapp CASCADE';
    ok $pg->deploy_step($step), 'Deploy "users" step';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha"/"beta" tag with "users" step';
    ok $pg->is_deployed_step($step), 'The "users" step should now be deployed';
    is_deeply [$pg->deployed_steps_for($tag)], [$step],
        'deployed_steps_for() should return the step';
    like $pg->current_tag_name, qr/^(?:alpha|beta)$/,
        'Should again have "alpha" or "beta" as current tag name';

    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [3, $pg->actor],
        'A record should have been inserted into the tags table once more';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 3], ['beta', 3]],
        'Both names should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 3, $pg->actor, [], []],
    ], 'A record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
    ], 'The step deploy should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'users'
        );
    })->[0], 'The users deploy script should have been run';

    # Now revert it.
    ok $pg->begin_revert_tag($tag), 'Begin reverting "alpha" tag with "users" step';
    ok $pg->revert_step($step), 'Revert "users" again';
    ok $pg->commit_revert_tag($tag), 'Commit "alpha"/"beta" tag with "users" step';
    ok !$pg->is_deployed_step($step), 'The "users" step should no longer be deployed';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'deployed_steps_for() should again return nothing';
    is $pg->current_tag_name, undef, 'Should once again have no current tag';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too, again';

    is $pg->_dbh->selectrow_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), undef, 'The step record should be removed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
    ], 'The step revert should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT NOT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'users'
        );
    })->[0], 'The users revert script should have been run';

    ##########################################################################
    # Now let's deploy two steps as part of the tag.
    my $step2 = App::Sqitch::Plan::Step->new(
        name => 'widgets',
        tag  => $tag,
    );

    ok !$pg->is_deployed_step($step2), 'The "widgets" step should not be deployed';
    ok $pg->begin_deploy_tag($tag), 'Begin deploying tag and two steps';
    ok $pg->deploy_step($step), 'Deploy "users" step again';
    ok $pg->deploy_step($step2), 'Deploy "widgets"step';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha"/"beta" tag with "users" step';
    ok $pg->is_deployed_step($step), 'The "users" step should be deployed again';
    ok $pg->is_deployed_step($step2), 'The "widgets" step should be deployed';
    is_deeply [map { $_->name } $pg->deployed_steps_for($tag)], [qw(users widgets)],
        'deployed_steps_for() should return both steps in order';
    like $pg->current_tag_name, qr/^(?:alpha|beta)$/,
        'Should once again "alpha" or "beta" as current tag name';

    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [4, $pg->actor],
        'A record should have been inserted into the tags table once more';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 4], ['beta', 4]],
        'Both names should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 4, $pg->actor, [], []],
        ['widgets', 4, $pg->actor, ['users'], ['dr_evil']],
    ], 'The requires and conflicts should be logged with "widgets" step';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'widgets', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
    ], 'Both steps should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'widgets'
        );
    })->[0], 'The widgets deploy script should have been run';

    # And revert them again.
    ok $pg->begin_revert_tag($tag), 'Begin reverting tag with two steps';
    ok $pg->revert_step($step2), 'Revert "widgets"';
    ok $pg->revert_step($step), 'Revert "users" again';
    ok $pg->commit_revert_tag($tag), 'Commit tag reversion with two steps';
    ok !$pg->is_deployed_step($step), 'The "users" step should not be deployed again';
    ok !$pg->is_deployed_step($step2), 'The "widgets" step should not be deployed again';
    is_deeply [$pg->deployed_steps_for($tag)], [],
        'deployed_steps_for should return nothing again';
    is $pg->current_tag_name, undef, 'Should again have no current tag';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too, again';

    is $pg->_dbh->selectrow_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), undef, 'The step record should be removed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at'
    ), [
        ['apply', '', ['alpha'], $pg->actor],
        ['remove', '', ['alpha'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'widgets', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['revert', 'widgets', ['alpha', 'beta'], $pg->actor],
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
    ], 'The step reverts should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT NOT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname IN ('users', 'widgets')
        );
    })->[0], 'The users and widgets revert scripts should have been run';

    ##########################################################################
    # And finally, separate them into two tags.
    ok $pg->begin_deploy_tag($tag), 'Begin tag with "users" step';
    ok $pg->deploy_step($step), 'Deploy "users" step once more';
    ok $pg->commit_deploy_tag($tag), 'Commit tag with "users" step';
    is_deeply [map { $_->name } $pg->deployed_steps_for($tag)], [qw(users)],
        'deployed_steps_for() should return the users step';
    like $pg->current_tag_name, qr/^(?:alpha|beta)$/,
        'Should once more have "alpha" or "beta" as current tag name';

    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [5, $pg->actor],
        'A record should have been inserted into the tags table once more';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5]],
        'Both names should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 5, $pg->actor, [], []],
    ], 'The "users" tag should be in the steps table';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'users'
        );
    })->[0], 'The "users" deploy script should have been run again';

    my $tag2 = App::Sqitch::Plan::Tag->new(
        names => ['gamma'],
        plan  => $plan,
    );

    $step2 = App::Sqitch::Plan::Step->new(
        name => 'widgets',
        tag  => $tag2,
    );

    ok $pg->is_deployed_tag($tag), 'The "alpha"/"beta" tag should be deployed';
    ok !$pg->is_deployed_tag($tag2), 'The "gamma" tag should not be deployed';
    ok $pg->begin_deploy_tag($tag2), 'Begin "gamma" tag with "widgets" step';
    ok $pg->deploy_step($step2), 'Deploy "widgets" step once more';
    ok $pg->commit_deploy_tag($tag2), 'Commit "gamma" tag with "widgets" step';
    ok $pg->is_deployed_tag($tag2), 'The "gamma" tag should now be deployed';

    is_deeply [map { $_->name } $pg->deployed_steps_for($tag)], [qw(users)],
        'deployed_steps_for() should return the users step for the first tag';
    is_deeply [map { $_->name } $pg->deployed_steps_for($tag2)], [qw(widgets)],
        'deployed_steps_for() should return the widgets step for the second tag';
    is $pg->current_tag_name, 'gamma', 'Now "gamma" should be current tag name';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
        [6, $pg->actor],
    ], 'Should have two tag records now';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5], ['gamma', 6]],
        'Names from both tags should be in tag_names';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 5, $pg->actor, [], []],
        ['widgets', 6, $pg->actor, ['users'], ['dr_evil']],
    ], 'Both steps should be in the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at OFFSET 12'
    ), [
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'widgets', ['gamma'], $pg->actor],
        ['apply', '', ['gamma'], $pg->actor],
    ], 'Both tags and steps should be logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'widgets'
        );
    })->[0], 'The "widgets" deploy script should have been run again';

    ##########################################################################
    # Test conflicts and requires.
    is_deeply [$pg->check_conflicts($step)], [], 'Step should have no conflicts';
    is_deeply [$pg->check_requires($step)], [], 'Step should have no missing prereqs';

    my $step3 = App::Sqitch::Plan::Step->new(
        name      => 'whatever',
        tag       => $tag,
        conflicts => ['users', 'widgets'],
        requires  => ['fred', 'barney', 'widgets'],
    );
    is_deeply [$pg->check_conflicts($step3)], [qw(users widgets)],
        'Should get back list of installed conflicting steps';
    is_deeply [$pg->check_requires($step3)], [qw(fred barney)],
        'Should get back list of missing prereq steps';

    # Revert gamma.
    ok $pg->begin_revert_tag($tag2), 'Begin reverting "gamma" step';
    ok $pg->revert_step($step2), 'Revert "gamma"';
    ok $pg->commit_revert_tag($tag2), 'Commit "gamma" reversion';
    ok !$pg->is_deployed_step($step2), 'The "widgets" step should no longer be deployed';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
    ], 'Should have only the one step record now';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5]],
        'Only the alpha tags should be in tag_names';

    is_deeply $pg->_dbh->selectall_arrayref(q{
        SELECT step, tag_id, deployed_by, requires, conflicts
          FROM steps
         ORDER BY deployed_at
    }), [
        ['users', 5, $pg->actor, [], []],
    ], 'Only the "users" step should be in the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at OFFSET 12'
    ), [
        ['revert', 'users', ['alpha', 'beta'], $pg->actor],
        ['remove', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'users', ['alpha', 'beta'], $pg->actor],
        ['apply', '', ['alpha', 'beta'], $pg->actor],
        ['deploy', 'widgets', ['gamma'], $pg->actor],
        ['apply', '', ['gamma'], $pg->actor],
        ['revert', 'widgets', ['gamma'], $pg->actor],
        ['remove', '', ['gamma'], $pg->actor],
    ], 'The revert and removal should have been logged';

    ok $pg->_dbh->selectcol_arrayref(q{
        SELECT NOT EXISTS(
            SELECT true
              FROM pg_catalog.pg_namespace n
              JOIN pg_catalog.pg_class c ON n.oid = c.relnamespace
             WHERE c.relkind = 'r'
               AND n.nspname = '__myapp'
               AND c.relname = 'widgets'
        );
    })->[0], 'The "widgets" revert script should have been run again';

    is_deeply [$pg->check_conflicts($step3)], [qw(users)],
        'Should now see only "users" as a conflict';
    is_deeply [$pg->check_requires($step3)], [qw(fred barney widgets)],
        'Should get back list all three missing prereq steps';

    ##########################################################################
    # Test failures.
    ok $pg->begin_deploy_tag($tag2), 'Begin "gamma" tag again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
        [7, $pg->actor],
    ], 'Should have only both tag records again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5], ['gamma', 7]],
        'Both sets of tag names should be present';

    ok $pg->log_fail_step($step2), 'Log the fail step';
    ok $pg->rollback_deploy_tag($tag2), 'Roll back "gamma" tag with "widgets" step';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_id, applied_by FROM tags ORDER BY applied_at'
    ), [
        [5, $pg->actor],
    ], 'Should have only the first tag record again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 5], ['beta', 5]],
        'Should have only the first tag names again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT event, step, tags, logged_by FROM events ORDER BY logged_at OFFSET 18'
    ), [
        ['revert', 'widgets', ['gamma'], $pg->actor],
        ['remove', '', ['gamma'], $pg->actor],
        ['fail', 'widgets', ['gamma'], $pg->actor],
    ], 'The failure should have been logged';
};

done_testing;
