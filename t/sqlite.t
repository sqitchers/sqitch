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
    $ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.user';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.sys';
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new( _engine => 'sqlite', db_name => 'foo.db' );
isa_ok my $sqlite = $CLASS->new(sqitch => $sqitch), $CLASS;

is $sqlite->client, 'sqlite3' . ($^O eq 'MSWin32' ? '.exe' : ''),
    'client should default to sqlite3';
is $sqlite->uri->dbname, file('foo.db'), 'dbname should be filled in';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be uri stringified';
is $sqlite->registry_destination, $sqlite->registry_uri->as_string,
    'Meta target should be registry_uri stringified';

# Make sure the password is suppressed in the destination, should anyone be
# silly enough to include on in an SQLite URI.
isa_ok $sqlite = $CLASS->new(
    sqitch => $sqitch,
    uri => URI->new('db:sqlite://foo:bar@localhost/my.db'),
), $CLASS;
is $sqlite->target, $sqlite->uri->as_string, 'Target should be the URI stringified';
like $sqlite->destination, qr{^db:sqlite://foo:?\@localhost/foo.db$},
    'Destination should exclude password';
like $sqlite->registry_destination, qr{^db:sqlite://foo:?\@localhost/sqitch\.db$},
    'Registry destination should also exclude password';

# Pretend for now that we always have a valid SQLite.
my $mock_sqitch = Test::MockModule->new(ref $sqitch);
my $sqlite_version = '3.7.12 2012-04-03 19:43:07 86b8481be7e76cccc92d14ce762d21bfb69504af';
$mock_sqitch->mock(probe => sub { $sqlite_version });

my @std_opts = (
    '-noheader',
    '-bail',
    '-batch',
    '-csv',
);

is_deeply [$sqlite->sqlite3], [$sqlite->client, @std_opts, $sqlite->uri->dbname],
    'sqlite3 command should have the proper opts';

##############################################################################
# Make sure we get an error for no database name.
throws_ok {
    $CLASS->new(sqitch => App::Sqitch->new( _engine => 'sqlite' ))->sqlite3
} 'App::Sqitch::X', 'Should get an error for no db name';
is $@->ident, 'sqlite', 'Missing db name error ident should be "sqlite"';
is $@->message,
    __x('Database name missing in URI {uri}', uri => 'db:sqlite:'),
    'Missing db name error message should be correct';

##############################################################################
# Make sure we get an error for no database name.
my $tmp_dir = Path::Class::dir( tempdir CLEANUP => 1 );
my $have_sqlite = try { $sqlite->use_driver };
$sqitch = App::Sqitch->new( _engine => 'sqlite' );
if ($have_sqlite) {
    # We have DBD::SQLite.
    # Find out if it's built with SQLite >= 3.7.11.
    my $dbh = DBI->connect('DBI:SQLite:');
    my @v = split /[.]/ => $dbh->{sqlite_version};
    $have_sqlite = $v[0] > 3 || ($v[0] == 3 && ($v[1] > 7 || ($v[1] == 7 && $v[2] >= 11)));
    unless ($have_sqlite) {
        # We have DBD::SQLite, but it is too old. Make sure we complain about that.
        isa_ok $sqlite = $CLASS->new(
            sqitch => $sqitch,
            registry => '_tmp',
        ), $CLASS;
        throws_ok { $sqlite->dbh } 'App::Sqitch::X', 'Should get an error for old SQLite';
        is $@->ident, 'sqlite', 'Unsupported SQLite error ident should be "sqlite"';
        is $@->message, __x(
            'Sqitch requires SQLite 3.7.11 or later; DBD::SQLite was built with {version}',
            version => $dbh->{sqlite_version}
        ), 'Unsupported SQLite error message should be correct';
    }
} else {
    # No DBD::SQLite at all.
    throws_ok { $sqlite->dbh } 'App::Sqitch::X',
        'Should get an error without DBD::SQLite';
    is $@->ident, 'sqlite', 'No DBD::SQLite error ident should be "sqlite"';
    is $@->message, __x(
        '{driver} required to manage {engine}',
        driver  => $sqlite->driver,
        engine  => $sqlite->name,
    ), 'No DBD::SQLite error message should be correct';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.sqlite.client'   => '/path/to/sqlite3',
    'core.sqlite.db_name'  => '/path/to/sqlite.db',
    'core.sqlite.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->client, '/path/to/sqlite3',
    'client should fall back on config';
is $sqlite->uri->as_string, 'db:sqlite:/path/to/sqlite.db',
    'dbname should fall back on config';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be configured uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be configured uri stringified';
is $sqlite->registry_uri->as_string, 'db:sqlite:/path/to/meta.db',
    'registry_uri should fall back on config';
is $sqlite->registry_destination, $sqlite->registry_uri->as_string,
    'Meta target should be configured registry_uri stringified';

# Try a registry with an extension and a dbname without.
%config = (
    'core.sqlite.db_name'  => '/path/to/sqitch',
    'core.sqlite.registry' => 'meta.db',
);
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->uri->as_string, 'db:sqlite:/path/to/sqitch',
    'dbname should fall back on config with no extension';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be configured uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be configured uri stringified';
is $sqlite->registry_uri->as_string, 'db:sqlite:/path/to/meta.db',
    'registry_uri should fall back on config wth extension';
is $sqlite->registry_destination, $sqlite->registry_uri->as_string,
    'Meta target should be configured registry_uri stringified';

# Also try a registry with no extension and a dbname with.
%config = (
    'core.sqlite.db_name'  => '/path/to/sqitch.db',
    'core.sqlite.registry' => 'registry',
);
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->uri->as_string, 'db:sqlite:/path/to/sqitch.db',
    'dbname should fall back on config with no extension';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be configured uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be configured uri stringified';
is $sqlite->registry_uri->as_string, 'db:sqlite:/path/to/registry.db',
    'registry_uri should fall back on config wth extension';
is $sqlite->registry_destination, $sqlite->registry_uri->as_string,
    'Meta target should be configured registry_uri stringified';

# Try a registry with an absolute path.
%config = (
    'core.sqlite.db_name'  => '/path/to/sqitch.db',
    'core.sqlite.registry' => '/some/other/path.db',
);
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create another sqlite';
is $sqlite->uri->as_string, 'db:sqlite:/path/to/sqitch.db',
    'dbname should fall back on config with no extension';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be configured uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be configured uri stringified';
is $sqlite->registry_uri->as_string, 'db:sqlite:/some/other/path.db',
    'registry_uri should fall back on config wth extension';
is $sqlite->registry_destination, $sqlite->registry_uri->as_string,
    'Meta target should be configured registry_uri stringified';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(_engine => 'sqlite', db_client => 'foo/bar', db_name => 'my.db');
ok $sqlite = $CLASS->new(sqitch => $sqitch),
    'Create sqlite with sqitch with --client and --db-name';
is $sqlite->client, 'foo/bar', 'The client should be grabbed from sqitch';
is $sqlite->uri->as_string, 'db:sqlite:' . file('my.db'),
    'The uri should be grabbed from sqitch';
is $sqlite->target, $sqlite->uri->as_string,
    'Target should be optioned uri stringified';
is $sqlite->destination, $sqlite->uri->as_string,
    'Destination should be optioned uri stringified';
is_deeply [$sqlite->sqlite3],
    [$sqlite->client, @std_opts, $sqlite->uri->dbname],
    'sqlite3 command should have option values';

$mock_config->unmock_all;

##############################################################################
# Test _read().
my $db_name = $tmp_dir->file('sqitch.db');
$sqitch = App::Sqitch->new(_engine => 'sqlite');
ok $sqlite = $CLASS->new(sqitch => $sqitch, uri => URI->new("db:sqlite:$db_name")),
    'Instantiate with a temporary database file';
can_ok $sqlite, qw(_read);
my $quote = $^O eq 'MSWin32' ? sub { $sqitch->quote_shell(shift) } : sub { shift };
SKIP: {
    skip 'DBD::SQLite not available', 3 unless $have_sqlite;
    is $sqlite->_read('foo'), $quote->(q{.read 'foo'}), '_read() should work';
    is $sqlite->_read('foo bar'), $quote->(q{.read 'foo bar'}),
        '_read() should SQL-quote the file name';
    is $sqlite->_read('foo \'bar\''), $quote->(q{.read 'foo ''bar'''}),
        '_read() should SQL-quote quotes, too';
}

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $sqlite, qw(_run _capture _spool);

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
SKIP: {
    skip 'DBD::SQLite not available', 2 unless $have_sqlite;
    ok $sqlite->run_file('foo/bar.sql'), 'Run foo/bar.sql';
    is_deeply \@run, [$sqlite->sqlite3, $quote->(".read 'foo/bar.sql'")],
        'File should be passed to run()';
}

ok $sqlite->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $sqlite->sqlite3],
    'Handle should be passed to spool()';

SKIP: {
    skip 'DBD::SQLite not available', 2 unless $have_sqlite;

    # Verify should go to capture unless verosity is > 1.
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
    is_deeply \@capture, [$sqlite->sqlite3, $quote->(".read 'foo/bar.sql'")],
        'Verify file should be passed to capture()';

    $mock_sqitch->mock(verbosity => 2);
    ok $sqlite->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
    is_deeply \@run, [$sqlite->sqlite3, $quote->(".read 'foo/bar.sql'")],
        'Verifile file should be passed to run() for high verbosity';
}

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
# Test checking the SQLite version.
for my $v (qw(
    3.3.9
    3.3.10
    3.3.200
    3.4.0
    3.4.8
    3.7.11
    3.8.12
    3.10.0
    4.1.30
)) {
    $sqlite_version = "$v 2012-04-03 19:43:07 86b8481be7e76cccc92d14ce762d21bfb69504af";
    ok my $sqlite = $CLASS->new(
        sqitch => $sqitch,
        uri => URI->new('db:sqlite:foo.db')
    ), "Create command for v$v";
    ok $sqlite->sqlite3, "Should be okay with sqlite v$v";
}

for my $v (qw(
    3.3.8
    3.3.0
    3.2.8
    3.0.1
    3.0.0
    2.8.1
    2.20.0
    1.0.0
)) {
    $sqlite_version = "$v 2012-04-03 19:43:07 86b8481be7e76cccc92d14ce762d21bfb69504af";
    ok my $sqlite = $CLASS->new(sqitch => $sqitch), "Create command for v$v";
    throws_ok { $sqlite->sqlite3 } 'App::Sqitch::X', "Should not be okay with v$v";
    is $@->ident, 'sqlite', qq{Should get ident "sqlite" for v$v};
    is $@->message,  __x(
        'Sqitch requires SQLite 3.3.9 or later; {client} is {version}',
        client  => $sqlite->client,
        version => $v
    ), "Should get proper error message for v$v";
}

$mock_sqitch->unmock_all;

##############################################################################
my $alt_db = $db_name->dir->file('sqitchtest.db');
# Can we do live tests?
END {
    my %drivers = DBI->installed_drivers;
    for my $driver (values %drivers) {
        $driver->visit_child_handles(sub {
            my $h = shift;
            $h->disconnect if $h->{Type} eq 'db' && $h->{Active};
        });
    }
}

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
        _engine   => 'sqlite',
    ],
    engine_params     => [ uri => URI->new("db:sqlite:$db_name") ],
    alt_engine_params => [
        uri        => URI->new("db:sqlite:$db_name"),
        registry      => 'sqitchtest',
    ],
    skip_unless       => sub {
        my $self = shift;

        # Should have the database handle and client.
        $self->dbh && $self->sqlite3;

        # Make sure we have a supported version.
        my $version = $self->dbh->{sqlite_version};
        my @v = split /[.]/ => $version;
        die "SQLite >= 3.7.11 required; DBD::SQLite built with $version\n"
            unless $v[0] > 3 || ($v[0] == 3 && ($v[1] > 7 || ($v[1] == 7 && $v[2] >= 11)));
    },
    engine_err_regex  => qr/^near "blah": syntax error/,
    init_error        =>  __x(
        'Sqitch database {database} already initialized',
        database => $alt_db,
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure foreign key constraints are enforced.
        ok $dbh->selectcol_arrayref('PRAGMA foreign_keys')->[0],
            'The foreign_keys pragma should be enabled';
    },
    add_second_format => q{strftime('%%Y-%%m-%%d %%H:%%M:%%f', strftime('%%J', %s) + (1/86400.0))},
);

done_testing;
