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

is $pg->target, $ENV{PGDATABASE} || $ENV{PGUSER} || $ENV{USER},
    'Target should fall back on environment variables';

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
# Test other configs for the target.
for my $env (qw(PGDATABASE PGUSER USER)) {
    my $pg = $CLASS->new(sqitch => $sqitch);
    local $ENV{$env} = "\$ENV=whatever";
    is $pg->target, "\$ENV=whatever", "Target should read \$$env";
}

ENV: {
    my $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->target, 'hi', 'Target shoul read username';

    local $ENV{PGDATABASE} = 'mydb';
    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $pg->target, 'mydb', 'Target should prefer $PGDATABASE to username';
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
is $pg->target, 'widgets', 'target should default to db_name';
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
is $pg->target, 'widgets_dev', 'target should still default to db_name';
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
    begin_deploy_tag
    commit_deploy_tag
    log_deploy_step
    begin_revert_tag
    commit_revert_tag
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
    ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with postgres user';
    try {
        $pg->_dbh;
    } catch {
        plan skip_all => 'Unable to connect to a database for testing';
    };

    plan 'no_plan';

    ok !$pg->initialized, 'Database should not yet be initialized';
    push @cleanup, 'DROP SCHEMA ' . $pg->sqitch_schema . ' CASCADE';
    ok $pg->initialize, 'Initialize the database';
    ok $pg->initialized, 'Database should now be initialized';

    # # Try it with a different schema name.
    my $mock_pg = Test::MockModule->new($CLASS);
    $mock_pg->mock(sqitch_schema => '__sqitchtest');
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
    my $step    = App::Sqitch::Plan::Step->new(
        name => 'users',
        tag  => $tag,
    );

    ok $pg->begin_deploy_tag($tag), 'Begin deploying "alpha" tag';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha" tag';
    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [1, $ENV{USER}],
        'A record should have been inserted into the tags table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [['alpha', 1]],
        'A record should have been inserted into the tag_names table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT step, tag_id, deployed_by, requires, conflicts FROM steps'
    ), [], 'No record should have been inserted into the steps table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT action, step, tags, taken_by, requires, conflicts FROM history'
    ), [], 'No record should have been inserted into the history table';

    # Now revert it.
    ok $pg->begin_revert_tag($tag), 'Begin reverting "alpha" tag';
    ok $pg->commit_revert_tag($tag), 'Commit "alpha" reversion';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too';

    # Let's have a couple of tag names.
    $tag = App::Sqitch::Plan::Tag->new(
        names => [qw(alpha beta)],
        plan  => $plan,
    );

    ok $pg->begin_deploy_tag($tag), 'Begin deploying "alpha" tag again';
    ok $pg->commit_deploy_tag($tag), 'Commit "alpha"/"beta" tag';
    is_deeply $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), [2, $ENV{USER}],
        'A record should have been inserted into the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names ORDER BY tag_name'
    ), [['alpha', 2], ['beta', 2]],
        'Both names should have been inserted into the tag_names taable';

    # Now revert it.
    ok $pg->begin_revert_tag($tag), 'Begin reverting "alpha"/"beta" tag';
    ok $pg->commit_revert_tag($tag), 'Commit "alpha"/"beta" reversion';

    is $pg->_dbh->selectrow_arrayref(
        'SELECT tag_id, applied_by FROM tags'
    ), undef, 'The record should be removed from the tags table again';

    is_deeply $pg->_dbh->selectall_arrayref(
        'SELECT tag_name, tag_id FROM tag_names'
    ), [], 'And from the tag_names table, too, again';
};

done_testing;
