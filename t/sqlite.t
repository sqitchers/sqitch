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
use Locale::TextDomain qw(App-Sqitch);
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;

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
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch, db_name => file 'foo.db'), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'MSWin32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->db_name, 'foo.db', 'db_name should be required';
is $sqlite->destination, $sqlite->db_name->stringify,
    'Destination should be db_name strintified';
is $sqlite->sqitch_db, file('foo')->dir->file('foo-sqitch.db'),
    'sqitch_db should default to "$db_name-sqitch.db" in the same diretory as db_name';
is $sqlite->meta_destination, $sqlite->sqitch_db->stringify,
    'Meta destination should be sqitch_db strintified';

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
throws_ok { $sqlite->dbh } 'App::Sqitch::X', 'Should get an error for no db name';
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
is $sqlite->meta_destination, $sqlite->sqitch_db->stringify,
    'Meta destination should be configured sqitch_db strintified';
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
my $tmp_dir = Path::Class::dir( tempdir CLEANUP => 1 );
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
can_ok $CLASS, '_ts2char_format';
is sprintf($CLASS->_ts2char_format, 'foo'),
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
my $alt_db = $db_name->dir->file('sqitchtest.db');
DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ db_name => $db_name ],
    alt_engine_params => [ db_name => $db_name, sqitch_db => $alt_db ],
    skip_unless       => sub { shift->dbh },
    engine_err_regex  => qr/^near "blah": syntax error/,
    init_error        =>  __x(
        'Sqitch database {database} already initialized',
        database => $alt_db,
    ),
    add_second_format => q{strftime('%%Y-%%m-%%d %%H:%%M:%%f', strftime('%%J', %s) + (1/86400.0))},
);

done_testing;
