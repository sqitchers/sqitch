#!/usr/bin/perl -w

# To test against a live ClickHouse database, you must set the
# SQITCH_TEST_CLICKHOUSE_URI environment variable. this is a standard URI::db
# URI, and should look something like this:
#
#     export SQITCH_TEST_CLICKHOUSE_URI=db:clickhouse://default@localhost/default?DSN=Clickhouse
#

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Test::File::Contents;
use Test::MockModule;
use Path::Class;
use Try::Tiny;
use Test::Exception;
use List::MoreUtils qw(firstidx);
use Locale::TextDomain qw(App-Sqitch);
use File::Temp 'tempdir';
use DBD::Mem;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::clickhouse';
    require_ok $CLASS or die;
    delete $ENV{$_} for grep { /^CLICKHOUSE_/ } keys %ENV;
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:clickhouse:default');
my $config = TestConfig->new(
    'core.engine' => 'clickhouse',
    'engine.clickhouse.target' => $uri->as_string,
);
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
isa_ok my $ch = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $ch->key, 'clickhouse', 'Key should be "clickhouse"';
is $ch->name, 'ClickHouse', 'Name should be "ClickHouse"';

my $client = 'clickhouse-client' . (App::Sqitch::ISWIN ? '.exe' : '');
is $ch->client, $client, 'client should default to clickhouse';
is $ch->registry, 'sqitch', 'registry default should be "sqitch"';
my $sqitch_uri = $uri->clone;
$sqitch_uri->dbname('sqitch');
is $ch->registry_uri, $sqitch_uri, 'registry_uri should be correct';
is $ch->uri, $uri, qq{uri should be "$uri"};
is $ch->_dsn, 'dbi:ODBC:DSN=default', 'DSN should use DBD::ODBC';
is $ch->registry_destination, 'db:clickhouse:sqitch',
    'registry_destination should be the same as registry_uri';

my @std_opts = (
    '--progress' => 'off',
    '--progress-table' => 'off',
    '--disable_suggestion',
);

my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my $warning;
$mock_sqitch->mock(warn => sub { shift; $warning = [@_] });
$ch->uri->dbname('');
is_deeply [$ch->cli], [$client, '--user', $sqitch->sysuser, @std_opts],
    'clickhouse command should be user and std opts-only';
is_deeply $warning, [__x
    'Database name missing in URI "{uri}"',
     uri => $ch->uri
], 'Should have emitted a warning for no database name';



$mock_sqitch->unmock_all;

$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri => URI::db->new('db:clickhouse:foo'),
);
isa_ok $ch = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

##############################################################################
# Make sure environment variables are read.
ENV: {
    local $ENV{CLICKHOUSE_USER} = 'kamala';
    local $ENV{CLICKHOUSE_PASSWORD} = '__KAMALA';
    ok my $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        'Create engine with env vars set set';
    is $ch->password, $ENV{CLICKHOUSE_PASSWORD},
        'Password should be set from environment';
    is $ch->username, $ENV{CLICKHOUSE_USER},
        'Username should be set from environment';
}

##############################################################################
# Make sure config settings override defaults and the password is set or removed
# as appropriate.
$config->update(
    'engine.clickhouse.client'   => '/path/to/clickhouse',
    'engine.clickhouse.target'   => 'db:clickhouse://me:pwd@foo.com/widgets',
    'engine.clickhouse.registry' => 'meta',
);
# my $ch_version = 'clickhouse  Ver 15.1 Distrib 10.0.15-MariaDB';
# $mock_sqitch->mock(probe => sub { $ch_version });
# push @std_opts => '--abort-source-on-error'
#     unless $std_opts[-1] eq '--abort-source-on-error';

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another clickhouse';
is $ch->client, '/path/to/clickhouse', 'client should be as configured';
is $ch->uri->as_string, 'db:clickhouse://me:pwd@foo.com/widgets',
    'URI should be as configured';
like $ch->target->name, qr{^db:clickhouse://me:?\@foo\.com/widgets$},
    'target name should be the URI without the password';
like $ch->destination, qr{^db:clickhouse://me:?\@foo\.com/widgets$},
    'destination should be the URI without the password';
is $ch->registry, 'meta', 'registry should be as configured';
is $ch->registry_uri->as_string, 'db:clickhouse://me:pwd@foo.com/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
like $ch->registry_destination, qr{^db:clickhouse://me:?\@foo\.com/meta$},
    'registry_destination should be the sqitch DB URL without the password';
is_deeply [$ch->cli], [
    '/path/to/clickhouse',
    'client',
    '--user',     'me',
    '--password', 'pwd',
    '--database', 'widgets',
    '--host',     'foo.com',
    @std_opts
], 'clickhouse command should be configured';

##############################################################################
# Make sure URI params get passed through to the client.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:clickhouse://foo.com/widgets?SSLMode=require',
));
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with query params';
is_deeply [$ch->cli], [
    qw(/path/to/clickhouse client),
    '--user', $sqitch->sysuser,
    qw(--database widgets --host foo.com),
    @std_opts,
    '--secure',
], 'clickhouse command should be configured with query vals';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $ch, qw(_run _capture _spool);
my $pass_env_name = 'CLICKHOUSE_PASSWORD';
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with sqitch with options';
$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $ch->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to run()';

ok $ch->_spool('FH'), 'Call _spool';
is_deeply \@spool, [['FH'], $ch->cli],
    'Command should be passed to spool()';

ok $ch->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with sqitch with no pw';
$exp_pass = undef;
$target->uri->password($exp_pass);
ok $ch->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $ch->_spool('FH'), 'Call _spool again';
is_deeply \@spool, [['FH'], $ch->cli],
    'Command should be passed to spool() again';

ok $ch->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $ch->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$ch->cli, '--query-file', 'foo/bar.sql'],
    'File should be passed to run()';
@run = ();

ok $ch->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, [['FH'], $ch->cli],
    'Handle should be passed to spool()';
@spool = ();

# Verify should go to capture unless verbosity is > 1.
ok $ch->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$ch->cli, '--query-file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';
@capture = ();

$mock_sqitch->mock(verbosity => 2);
ok $ch->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$ch->cli, '--query-file', 'foo/bar.sql'],
    'Verify file should be passed to run() for high verbosity';
@run = ();

$ch->clear_variables;
$mock_sqitch->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char_format';
is sprintf($CLASS->_ts2char_format, 'foo'),
    q{formatDateTime(foo, 'year:%Y:month:%m:day:%d:hour:%H:minute:%i:second:%S:time_zone:UTC')},
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
# Test SQL helpers.
is $ch->_listagg_format, q{groupArraySorted(10000)(%1$s)},
    'Should have _listagg_format';
is $ch->_regex_op, 'REGEXP', 'Should have _regex_op';
is $ch->_simple_from, '', 'Should have _simple_from';
is $ch->_limit_default, undef, 'Should have no _limit_default';

is $ch->_ts_default, q{now64(6, 'UTC')},
    'Should have _ts_default with now64()';

DBI: {
    local *DBI::state;
    ok !$ch->_no_table_error, 'Should have no table error';
    ok !$ch->_no_column_error, 'Should have no column error';
    $DBI::state = '42S02';
    ok $ch->_no_table_error, 'Should now have table error';
    ok !$ch->_no_column_error, 'Still should have no column error';
    $DBI::state = '42703';
    ok !$ch->_no_table_error, 'Should again have no table error';
    ok $ch->_no_column_error, 'Should now have no column error';
    ok !$ch->_unique_error, 'Unique constraints not supported by Snowflake';
}


is_deeply [$ch->_limit_offset(8, 4)],
    [['LIMIT ?', 'OFFSET ?'], [8, 4]],
    'Should get limit and offset';
is_deeply [$ch->_limit_offset(0, 2)], [['OFFSET ?'], [2]],
    'Should get limit and offset when offset only';
is_deeply [$ch->_limit_offset(12, 0)], [['LIMIT ?'], [12]],
    'Should get only limit with 0 offset';
is_deeply [$ch->_limit_offset(12)], [['LIMIT ?'], [12]],
    'Should get only limit with noa offset';
is_deeply [$ch->_limit_offset(0, 0)], [[], []],
    'Should get no limit or offset for 0s';
is_deeply [$ch->_limit_offset()], [[], []],
    'Should get no limit or offset for no args';

is_deeply [$ch->_regex_expr('corn', 'Obama$')],
    ['corn REGEXP ?', 'Obama$'],
    'Should use REGEXP for regex expr';

##############################################################################
# Test unexpected database error in initialized() and _cid().
MOCKDBH: {
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(dbh => sub { die 'OW' });
    throws_ok { $ch->initialized } qr/OW/,
        'initialized() should rethrow unexpected DB error';
    throws_ok { $ch->_cid } qr/OW/,
        '_cid should rethrow unexpected DB error';
}

##############################################################################
# Test run_upgrade().
UPGRADE: {
    my $mock = Test::MockModule->new($CLASS);
    my $fracsec;
    my $version = 50500;
    $mock->mock(_fractional_seconds => sub { $fracsec });
    $mock->mock(dbh => sub { { mariadb_serverversion => $version } });
    $mock->mock(_create_check_function => 1);

    # Mock run.
    my @run;
    $mock_sqitch->mock(run => sub { shift; @run = @_ });

    # Mock File::Temp so we hang on to the file.
    my $mock_ft = Test::MockModule->new('File::Temp');
    my $tmp_fh;
    my $ft_new;
    $mock_ft->mock(new => sub { $tmp_fh = 'File::Temp'->$ft_new() });
    $ft_new = $mock_ft->original('new');

    # Assemble the expected command.
    my @cmd = $ch->cli;
    my $db_opt_idx = firstidx { $_ eq '--database' } @cmd;
    $cmd[$db_opt_idx + 1] = $ch->registry;
    my $fn = file($INC{'App/Sqitch/Engine/clickhouse.pm'})->dir->file('clickhouse.sql');

    # Test the upgrade.
    ok $ch->run_upgrade($fn), 'Run the upgrade';
    is $tmp_fh, undef, 'Should not have created a temp file';
    is_deeply \@run, [@cmd, '--query-file', $fn],
        'It should have run the unchanged file';

    $mock_sqitch->unmock_all;
}

# Make sure we have templates.
DBIEngineTest->test_templates_for($ch->key);

##############################################################################
# Can we do live tests?
my $dbh;
my $id = DBIEngineTest->randstr;
my ($db, $reg1, $reg2) = map { $_ . $id } qw(__sqitchtest__ __metasqitch __sqitchtest);

END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    return unless $dbh->{Active};
    $dbh->do("DROP DATABASE IF EXISTS $_") for ($db, $reg1, $reg2);
}

$uri = URI->new(
    $ENV{SQITCH_TEST_CLICKHOUSE_URI} ||
    'db:clickhouse://default@localhost/default?Driver=ClickHouse'
);
$uri->dbname('default') unless $uri->dbname;
my $err = try {
    $ch->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError  => 0,
        RaiseError  => 0,
        AutoCommit  => 1,
        HandleError => $ch->error_handler,
    });

    $dbh->do("CREATE DATABASE $db");
    $uri->dbname($db);
    undef;
} catch {
    $_
};

DBIEngineTest->run(
    class             => $CLASS,
    target_params     => [ registry => $reg1, uri => $uri ],
    alt_target_params => [ registry => $reg2, uri => $uri ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have clickhouse and can connect to the database.
        my $version = $self->sqitch->capture( $self->client, '--version' );
        say "# Detected CLI $version";
        say '# Connected to ClickHouse ' . $self->_capture('--execute' => 'SELECT version()');
        1;
    },
    engine_err_regex  => qr/^You have an error /,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => $reg2,
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Special-case sql_mode.
        my $sql_mode = $dbh->selectcol_arrayref('SELECT @@SESSION.sql_mode')->[0];
        for my $mode (qw(
                ansi
                strict_trans_tables
                no_auto_value_on_zero
                no_zero_date
                no_zero_in_date
                only_full_group_by
                error_for_division_by_zero
        )) {
            like $sql_mode, qr/\b\Q$mode\E\b/i, "sql_mode should include $mode";
        }
    },
        lock_sql => sub {
            my $lock_name = shift->_lock_name; return {
            is_locked  => "SELECT is_used_lock('$lock_name')",
            try_lock   => "SELECT get_lock('$lock_name', 0)",
            wait_time  => 1, # get_lock() does not support sub-second precision, apparently.
            async_free => 1,
            free_lock  => 'SELECT ' . ($dbh ? do {
                # ClickHouse 5.5-5.6 and Maria 10.0-10.4 prefer release_lock(), while
                # 5.7+ and 10.5+ prefer release_all_locks().
                $dbh->selectrow_arrayref('SELECT version()')->[0] =~ /^(?:5\.[56]|10\.[0-4])/
                    ? "release_lock('$lock_name')"
                    : 'release_all_locks()'
            } : ''),
        } },
);

done_testing;
