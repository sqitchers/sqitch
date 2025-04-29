#!/usr/bin/perl -w

# There are two ways to test against a live Postgres database. If there is an
# instance on the local host trusting all local socket connections and the
# default postgres user, the test will connect, create the database it needs,
# run the tests, and then drop the database.
#
# Alternatively, provide the URL to connect to a Postgres database in the
# SQITCH_TEST_PG_URI environment variable. this is a standard URI::db URI, and
# should look something like this:
#
#     export SQITCH_TEST_PG_URI=db:pg://postgres:password@localhost:5432/sqitchtest
#
# It should use the C locale (`ALTER DATABASE $db SET lc_messages = 'C'`) to
# ensure proper sorting while testing. Sqitch will connect to this database and
# create two schemas to run the tests in, `sqitch` and `__sqitchtest`, and will
# drop them when the tests complete.
#

use strict;
use warnings;
use 5.010;
use Test::More 0.94;
use Test::MockModule;
use Test::Exception;
use Test::File::Contents;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny 0.12 qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use Path::Class;
use DBD::Mem;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::pg';
    require_ok $CLASS or die;
    delete $ENV{PGPASSWORD};
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:pg:');
my $config = TestConfig->new('core.engine' => 'pg');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $pg = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $pg->key, 'pg', 'Key should be "pg"';
is $pg->name, 'PostgreSQL', 'Name should be "PostgreSQL"';

my $client = 'psql' . (App::Sqitch::ISWIN ? '.exe' : '');
is $pg->client, $client, 'client should default to psqle';
is $pg->registry, 'sqitch', 'registry default should be "sqitch"';
is $pg->uri, $uri, 'DB URI should be "db:pg:"';
my $dest_uri = $uri->clone;
$dest_uri->dbname($ENV{PGDATABASE} || $ENV{PGUSER} || $sqitch->sysuser);
is $pg->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $pg->registry_destination, $pg->destination,
    'Registry destination should be the same as destination';

my @std_opts = (
    '--quiet',
    '--no-psqlrc',
    '--no-align',
    '--tuples-only',
    '--set' => 'ON_ERROR_STOP=1',
    '--set' => 'registry=sqitch',
);
my $sysuser = $sqitch->sysuser;
is_deeply [$pg->psql], [$client, @std_opts],
    'psql command should be conninfo, and std opts-only';

isa_ok $pg = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
ok $pg->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$pg->psql], [
    $client,
    '--set'    => 'foo=baz',
    '--set'    => 'whu=hi there',
    '--set'    => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to psql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{PGDATABASE};
    for my $env (qw(PGDATABASE PGUSER PGPASSWORD)) {
        my $pg = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = "\$ENV=whatever";
        is $pg->target->uri, "db:pg:", "Target should not read \$$env";
        is $pg->registry_destination, $pg->destination,
            'Registry target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $pg = $CLASS->new(sqitch => $sqitch, target => $target);
    is $pg->target->uri, 'db:pg:', 'Target should not fall back on sysuser';
    is $pg->registry_destination, $pg->destination,
        'Registry target should be the same as destination';

    $ENV{PGDATABASE} = 'mydb';
    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $pg->target->uri, 'db:pg:',  'Target should be the default';
    is $pg->registry_destination, $pg->destination,
        'Registry target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
$config->update(
    'engine.pg.client'   => '/path/to/psql',
    'engine.pg.target'   => 'db:pg://localhost/try?sslmode=disable&connect_timeout=5',
    'engine.pg.registry' => 'meta',
);
$std_opts[-1] = 'registry=meta';

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $pg = $CLASS->new(sqitch => $sqitch, target => $target), 'Create another pg';
is $pg->client, '/path/to/psql', 'client should be as configured';
is $pg->uri->as_string, 'db:pg://localhost/try?sslmode=disable&connect_timeout=5',
    'uri should be as configured';
is $pg->registry, 'meta', 'registry should be as configured';
is_deeply [$pg->psql], [
    '/path/to/psql',
    '--dbname',
    "dbname=try host=localhost connect_timeout=5 sslmode=disable",
@std_opts], 'psql command should be configured from URI config';

##############################################################################
# Test _run(), _capture(), _spool(), and _probe().
can_ok $pg, qw(_run _capture _spool _probe);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
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
    local $Test::Builder::Level = $Test::Builder::Level + 2;
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
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

my @probe;
$mock_sqitch->mock(probe => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @probe = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

$target->uri->password('s3cr3t');
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

ok $pg->_probe(qw(hi there)), 'Call _probe';
is_deeply \@probe, [$pg->psql, qw(hi there)];

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $pg = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a pg with sqitch with no pw';
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

ok $pg->_probe(qw(go there)), 'Call _probe again';
is_deeply \@probe, [$pg->psql, qw(go there)];

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

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->($pg), 'foo'),
    q{to_char(foo AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')},
    '_ts2char_format should work';

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
# Test _psql_major_version.
for my $spec (
    ['11beta3', 11],
    ['11.3',    11],
    ['10',      10],
    ['9.6.3',    9],
    ['8.4.2',    8],
    ['9.0.19',   9],
) {
    $mock_sqitch->mock(probe => "psql (PostgreSQL) $spec->[0]");
    is $pg->_psql_major_version, $spec->[1],
        "Should find major version $spec->[1] in $spec->[0]";
}
$mock_sqitch->unmock('probe');

##############################################################################
# Test table error and listagg methods.
DBI: {
    local *DBI::state;
    ok !$pg->_no_table_error, 'Should have no table error';
    ok !$pg->_no_column_error, 'Should have no column error';

    $DBI::state = '42703';
    ok !$pg->_no_table_error, 'Should again have no table error';
    ok $pg->_no_column_error, 'Should now have no column error';

    # Need to mock DBH for table errors.
    my $dbh = DBI->connect('dbi:Mem:', undef, undef, {});
    my $mock_engine = Test::MockModule->new($CLASS);
    $mock_engine->mock(dbh => $dbh);
    my $mock_dbd = Test::MockModule->new(ref $dbh, no_auto => 1);
    $mock_dbd->mock(quote => sub { qq{'$_[1]'} });
    my @done;
    $mock_dbd->mock(do => sub { shift; @done = @_ });

    # Should just work when on 8.4.
    $DBI::state = '42P01';
    $dbh->{pg_server_version} = 80400;
    ok $pg->_no_table_error, 'Should now have table error';
    ok !$pg->_no_column_error, 'Still should have no column error';
    is_deeply \@done, [], 'No SQL should have been run';

    # On 9.0 and later, we should send warnings to the log.
    $dbh->{pg_server_version} = 90000;
    ok $pg->_no_table_error, 'Should again have table error';
    ok !$pg->_no_column_error, 'Still should have no column error';
    is_deeply \@done, [sprintf q{DO $$
        BEGIN
            SET LOCAL client_min_messages = 'ERROR';
            RAISE WARNING USING ERRCODE = 'undefined_table', MESSAGE = %s, DETAIL = %s;
        END;
    $$}, map { "'$_'" }
        __ 'Sqitch registry not initialized',
        __ 'Because the "changes" table does not exist, Sqitch will now initialize the database to create its registry tables.',
    ], 'Should have sent an error to the log';

    # Test _listagg_format.
    $dbh->{pg_server_version} = 110000;
    is $pg->_listagg_format, q{array_remove(array_agg(%1$s ORDER BY %1$s), NULL)},
        'Should use array_remove and ORDER BY in listagg_format on v11';

    $dbh->{pg_server_version} = 90300;
    is $pg->_listagg_format, q{array_remove(array_agg(%1$s ORDER BY %1$s), NULL)},
        'Should use array_remove and ORDER BY in listagg_format on v9.3';

    $dbh->{pg_server_version} = 90200;
    is $pg->_listagg_format,
        q{ARRAY(SELECT * FROM UNNEST( array_agg(%1$s ORDER BY %1$s) ) a WHERE a IS NOT NULL)},
        'Should use ORDER BY in listagg_format on v9.2';

    $dbh->{pg_server_version} = 90000;
    is $pg->_listagg_format,
        q{ARRAY(SELECT * FROM UNNEST( array_agg(%1$s ORDER BY %1$s) ) a WHERE a IS NOT NULL)},
        'Should use ORDER BY in listagg_format on v9.0';

    $dbh->{pg_server_version} = 80400;
    is $pg->_listagg_format,
        q{ARRAY(SELECT * FROM UNNEST( array_agg(%s) ) a WHERE a IS NOT NULL)},
        'Should not use ORDER BY in listagg_format on v8.4';
}

##############################################################################
# Test _run_registry_file.
RUNREG: {
    # Mock I/O used by _run_registry_file.
    my $mock_engine = Test::MockModule->new($CLASS);
    my (@probed, @prob_ret);
    $mock_engine->mock(_probe => sub {
        shift;
        push @probed, \@_;
        shift @prob_ret;
    });
    my $psql_maj;
    $mock_engine->mock(_psql_major_version => sub { $psql_maj });
    my @ran;
    $mock_engine->mock(_run => sub { shift; push @ran, \@_ });

    # Mock up the database handle.
    my $dbh = DBI->connect('dbi:Mem:', undef, undef, {});
    $mock_engine->mock(dbh => $dbh );
    my $mock_dbd = Test::MockModule->new(ref $dbh, no_auto => 1);
    my @done;
    $mock_dbd->mock(do => sub { shift; push @done, \@_; 1 });
    my @sra_args;
    $mock_dbd->mock(selectrow_array => sub {
        shift;
        push @sra_args, [@_];
        return (qq{"$_[-1]"});
    });

    # Mock File::Temp so we hang on to the file.
    my $mock_ft = Test::MockModule->new('File::Temp');
    my $tmp_fh;
    my $ft_new;
    $mock_ft->mock(new => sub { $tmp_fh = 'File::Temp'->$ft_new() });
    $ft_new = $mock_ft->original('new');

    # Find the SQL file.
    my $ddl = file($INC{'App/Sqitch/Engine/pg.pm'})->dir->file('pg.sql');

    # The XC query.
    my $xc_query = q{
        SELECT count(*)
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
         WHERE nspname = 'pg_catalog'
           AND proname = 'pgxc_version';
    };

    # Start with a recent version and no XC.
    $psql_maj = 11;
    @prob_ret = (110000, 0);
    my $registry = $pg->registry;
    ok $pg->_run_registry_file($ddl), 'Run the registry file';
    is_deeply \@probed, [
        ['-c', 'SHOW server_version_num'],
        ['-c', $xc_query],
    ], 'Should have fetched the server version and checked for XC';
    is_deeply \@ran, [[
        '--file' => $ddl,
        '--set'  => "registry=$registry",
        '--set'  => "tableopts=",
    ]], 'Shoud have deployed the original SQL file';
    is_deeply \@done, [['SET search_path = ?', undef, $registry]],
        'The registry should have been added to the search path';
    is_deeply \@sra_args, [], 'Should not have have called selectrow_array';
    is $tmp_fh, undef, 'Should have no temp file handle';

    # Reset and try Postgres 9.2 server
    @probed = @ran = @done = ();
    $psql_maj = 11;
    @prob_ret = (90200, 1);
    ok $pg->_run_registry_file($ddl), 'Run the registry file again';
    is_deeply \@probed, [
        ['-c', 'SHOW server_version_num'],
        ['-c', $xc_query],
    ], 'Should have again fetched the server version and checked for XC';
    isnt $tmp_fh, undef, 'Should now have a temp file handle';
    is_deeply \@ran, [[
        '--file' => $tmp_fh,
        '--set'  => "tableopts= DISTRIBUTE BY REPLICATION",
    ]], 'Shoud have deployed the temp SQL file';
    is_deeply \@sra_args, [], 'Still should not have have called selectrow_array';
    is_deeply \@done, [['SET search_path = ?', undef, $registry]],
        'The registry should have been added to the search path again';

    # Make sure the file was changed to remove SCHEMA IF NOT EXISTS.
    file_contents_like $tmp_fh, qr/\QCREATE SCHEMA :"registry";/,
        'Should have removed IF NOT EXISTS from CREATE SCHEMA';

    # Reset and try with Server 11 and psql 8.x.
    @probed = @ran = @done = ();
    $psql_maj = 8;
    $tmp_fh = undef;
    @prob_ret = (110000, 0);
    ok $pg->_run_registry_file($ddl), 'Run the registry file again';
    is_deeply \@probed, [
        ['-c', 'SHOW server_version_num'],
        ['-c', $xc_query],
    ], 'Should have again fetched the server version and checked for XC';
    isnt $tmp_fh, undef, 'Should now have a temp file handle';
    is_deeply \@ran, [[
        '--file' => $tmp_fh,
        '--set'  => "tableopts=",
    ]], 'Shoud have deployed the temp SQL file';
    is_deeply \@sra_args, [['SELECT quote_ident(?)', undef, $registry]],
        'Should have have called quote_ident via selectrow_array';
    is_deeply \@done, [['SET search_path = ?', undef, qq{"$registry"}]],
        'The registry should have been added to the search path again';

    file_contents_like $tmp_fh, qr/\QCREATE SCHEMA IF NOT EXISTS "$registry";/,
        'Should not have removed IF NOT EXISTS from CREATE SCHEMA';
    file_contents_unlike $tmp_fh, qr/:"registry"/,
        'Should have removed the :"registry" variable';
}

# Make sure we have templates.
DBIEngineTest->test_templates_for($pg->key);

##############################################################################
# Can we do live tests?
$config->replace('core.engine' => 'pg');
$sqitch = App::Sqitch->new(config => $config);
$target = App::Sqitch::Target->new( sqitch => $sqitch );
$pg     = $CLASS->new(sqitch => $sqitch, target => $target);

$uri = URI->new(
    $ENV{SQITCH_TEST_PG_URI}
    || 'db:pg://' . ($ENV{PGUSER} || 'postgres') . "\@/template1"
);

my $dbh;
my $id = DBIEngineTest->randstr;
my ($db, $reg1, $reg2) = map { $_ . $id } qw(__sqitchtest__ sqitch __sqitchtest);

END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    # Drop the database or schema.
    if ($dbh->{Active}) {
        if ($ENV{SQITCH_TEST_PG_URI}) {
            $dbh->do('SET client_min_messages = warning');
            $dbh->do("DROP SCHEMA $_ CASCADE") for $reg1, $reg2;
        } else {
            $dbh->do("DROP DATABASE $db");
        }
    }
}

my $err = try {
    $pg->_capture('--version');
    $pg->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError     => 0,
        RaiseError     => 0,
        AutoCommit     => 1,
        HandleError    => $pg->error_handler,
        pg_lc_messages => 'C',
    });
    unless ($ENV{SQITCH_TEST_PG_URI}) {
        $dbh->do("CREATE DATABASE $db");
        $uri->dbname($db);
    }
    undef;
} catch {
    $_
};

DBIEngineTest->run(
    class             => $CLASS,
    version_query     => 'SELECT version()',
    target_params     => [ uri => $uri, registry => $reg1 ],
    alt_target_params => [ uri => $uri, registry => $reg2 ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have psql and can connect to the database.
        my $version = $self->sqitch->capture( $self->client, '--version' );
        say "# Detected $version";
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/^ERROR:  /,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $reg2,
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            $reg2, 'The Sqitch schema should be the current schema';
    },
    lock_sql => sub {
        my $engine = shift;
        return {
            is_locked => q{SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND objid = 75474063 AND objsubid = 1},
            try_lock  => 'SELECT pg_try_advisory_lock(75474063)',
            free_lock => 'SELECT pg_advisory_unlock_all()',
        } if $engine->_provider ne 'yugabyte';
        return undef;
    },
);

done_testing;
