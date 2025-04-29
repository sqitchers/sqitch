#!/usr/bin/perl -w

# To test against a live Exasol database, you must set the
# SQITCH_TEST_EXASOL_URI environment variable. this is a stanard URI::db URI,
# and should look something like this:
#
#     export SQITCH_TEST_EXASOL_URI=db:exasol://dbadmin:password@localhost:5433/dbadmin?Driver=Exasol
#
# Note that it must include the `?Driver=$driver` bit so that DBD::ODBC loads
# the proper driver.

use strict;
use warnings;
use 5.010;
use Test::More;
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny 0.12 qw(:all);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

delete $ENV{"VSQL_$_"} for qw(USER PASSWORD DATABASE HOST PORT);

BEGIN {
    $CLASS = 'App::Sqitch::Engine::exasol';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:exasol:');
my $config = TestConfig->new('core.engine' => 'exasol');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $exa = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $exa->key, 'exasol', 'Key should be "exasol"';
is $exa->name, 'Exasol', 'Name should be "Exasol"';

my $client = 'exaplus' . (App::Sqitch::ISWIN ? '.exe' : '');
is $exa->client, $client, 'client should default to exaplus';
is $exa->registry, 'sqitch', 'registry default should be "sqitch"';
is $exa->uri, $uri, 'DB URI should be "db:exasol:"';
my $dest_uri = $uri->clone;
is $exa->destination, $dest_uri->as_string,
    'Destination should default to "db:exasol:"';
is $exa->registry_destination, $exa->destination,
    'Registry destination should be the same as destination';

my @std_opts = (
    '-q',
    '-L',
    '-pipe',
    '-x',
    '-autoCompletion' => 'OFF',
    '-encoding' => 'UTF8',
    '-autocommit' => 'OFF',
);

is_deeply [$exa->exaplus], [$client, @std_opts],
    'exaplus command should be std opts-only';

is $exa->_script, join( "\n" => (
    'SET FEEDBACK OFF;',
    'SET HEADING OFF;',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    $exa->_registry_variable,
) ), '_script should work';

ok $exa->set_variables(foo => 'baz', whu => 'hi there', yo => q{'stellar'}),
    'Set some variables';

is $exa->_script, join( "\n" => (
    'SET FEEDBACK OFF;',
    'SET HEADING OFF;',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    "DEFINE foo='baz';",
    "DEFINE whu='hi there';",
    "DEFINE yo='''stellar''';",
    $exa->_registry_variable,
) ), '_script should assemble variables';

##############################################################################
# Make sure the URI query properly affect the client options.
for my $spec (
    {
        qry => 'SSLCERTIFICATE=SSL_VERIFY_NONE',
        opt => [qw(-jdbcparam validateservercertificate=0)],
    },
    {
        qry => 'SSLCERTIFICATE=SSL_VERIFY_NONE',
        opt => [qw(-jdbcparam validateservercertificate=0)],
    },
    {
        qry => 'SSLCERTIFICATE=xxx',
        opt => [],
    },
    {
        qry => 'SSLCERTIFICATE=SSL_VERIFY_NONE&SSLCERTIFICATE=xyz',
        opt => [],
    },
    {
        qry => 'AuthMethod=refreshtoken',
        opt => [qw(-jdbcparam authmethod=refreshtoken)],
    },
    {
        qry => 'AUTHMETHOD=xyz',
        opt => [qw(-jdbcparam authmethod=xyz)],
    },
    {
        qry => 'SSLCERTIFICATE=SSL_VERIFY_NONE&AUTHMETHOD=xyz',
        opt => [qw(-jdbcparam validateservercertificate=0 -jdbcparam authmethod=xyz)],
    },
) {
    $uri->query($spec->{qry});
    my $target = App::Sqitch::Target->new(
        sqitch => $sqitch,
        uri    => $uri,
    );
    my $exa = $CLASS->new(
        sqitch => $sqitch,
        target => $target,
    );
    is_deeply [$exa->exaplus], [$client, @{ $spec->{opt} }, @std_opts],
        "Should handle query $spec->{qry}";
}
$uri->query('');

##############################################################################
# Test other configs for the target.
ENV: {
    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $exa = $CLASS->new(sqitch => $sqitch, target => $target);
    is $exa->target->name, 'db:exasol:',
        'Target name should NOT fall back on sysuser';
    is $exa->registry_destination, $exa->destination,
        'Registry target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
$config->update(
    'engine.exasol.client'   => '/path/to/exaplus',
    'engine.exasol.target'   => 'db:exasol://me:myself@localhost:4444',
    'engine.exasol.registry' => 'meta',
);

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $exa = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another exasol';
is $exa->client, '/path/to/exaplus', 'client should be as configured';
is $exa->uri->as_string, 'db:exasol://me:myself@localhost:4444',
    'uri should be as configured';
is $exa->registry, 'meta', 'registry should be as configured';
is_deeply [$exa->exaplus], [qw(
    /path/to/exaplus
    -u me
    -p myself
    -c localhost:4444
), @std_opts], 'exaplus command should be configured from URI config';

is $exa->_script, join( "\n" => (
    'SET FEEDBACK OFF;',
    'SET HEADING OFF;',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'DEFINE registry=meta;',
) ), '_script should use registry from config settings';

##############################################################################
# Test _run() and _capture().
can_ok $exa, qw(_run _capture);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@capture, @spool);
$mock_sqitch->mock(spool   => sub { shift; @spool = @_ });
my $mock_run3 = Test::MockModule->new('IPC::Run3');
$mock_run3->mock(run3 => sub { @capture = @_ });

ok $exa->_run(qw(foo bar baz)), 'Call _run';
my $fh = shift @spool;
is_deeply \@spool, [$exa->exaplus],
    'EXAplus command should be passed to spool()';

is join('', <$fh> ), $exa->_script(qw(foo bar baz)),
    'The script should be spooled';

ok $exa->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [
    [$exa->exaplus], \$exa->_script(qw(foo bar baz)), [], [],
    { return_if_system_error => 1 },
], 'Command and script should be passed to run3()';

# Let's make sure that IPC::Run3 actually works as expected.
$mock_run3->unmock_all;
my $echo = Path::Class::file(qw(t echo.pl));
my $mock_exa = Test::MockModule->new($CLASS);
$mock_exa->mock(exaplus => sub { $^X, $echo, qw(hi there) });

is join (', ' => $exa->_capture(qw(foo bar baz))), "hi there\n",
    '_capture should actually capture';

# Make it die.
my $die = Path::Class::file(qw(t die.pl));
$mock_exa->mock(exaplus => sub { $^X, $die, qw(hi there) });
like capture_stderr {
    throws_ok {
        $exa->_capture('whatever'),
    } 'App::Sqitch::X', '_capture should die when exaplus dies';
}, qr/^OMGWTF/m, 'STDERR should be emitted by _capture';

##############################################################################
# Test unexpeted datbase error in _cid().
$mock_exa->mock(dbh => sub { die 'OW' });
throws_ok { $exa->initialized } qr/OW/,
    'initialized() should rethrow unexpected DB error';
throws_ok { $exa->_cid } qr/OW/,
    '_cid should rethrow unexpected DB error';
$mock_exa->unmock('dbh');

##############################################################################
# Test _file_for_script().
can_ok $exa, '_file_for_script';
is $exa->_file_for_script(Path::Class::file 'foo'), 'foo',
    'File without special characters should be used directly';
is $exa->_file_for_script(Path::Class::file '"foo"'), '""foo""',
    'Double quotes should be SQL-escaped';

# Get the temp dir used by the engine.
ok my $tmpdir = $exa->tmpdir, 'Get temp dir';
isa_ok $tmpdir, 'Path::Class::Dir', 'Temp dir';

# Make sure a file with @ is aliased.
my $file = $tmpdir->file('foo@bar.sql');
$file->touch; # File must exist, because on Windows it gets copied.
is $exa->_file_for_script($file), $tmpdir->file('foo_bar.sql'),
    'File with special char should be aliased';

# Now the alias exists, make sure _file_for_script dies if it cannot remove it.
FILE: {
    my $mock_pcf = Test::MockModule->new('Path::Class::File');
    $mock_pcf->mock(remove => 0);
    throws_ok { $exa->_file_for_script($file) } 'App::Sqitch::X',
        'Should get an error on failure to delete the alias';
    is $@->ident, 'exasol', 'File deletion error ident should be "exasol"';
    is $@->message, __x(
        'Cannot remove {file}: {error}',
        file  => $tmpdir->file('foo_bar.sql'),
        error => $!,
    ), 'File deletion error message should be correct';
}

# Make sure double-quotes are escaped.
WIN32: {
    $file = $tmpdir->file('"foo$bar".sql');
    my $mock_file = Test::MockModule->new(ref $file);
    # Windows doesn't like the quotation marks, so prevent it from writing.
    $mock_file->mock(copy_to => 1) if App::Sqitch::ISWIN;
    is $exa->_file_for_script($file), $tmpdir->file('""foo_bar"".sql'),
        'File with special char and quotes should be aliased';
}

##############################################################################
# Test file and handle running.
my @run;
$mock_exa->mock(_capture => sub {shift; @run = @_ });
ok $exa->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, ['@"foo/bar.sql"'],
    'File should be passed to capture()';

ok $exa->run_file('foo/"bar".sql'), 'Run foo/"bar".sql';
is_deeply \@run, ['@"foo/""bar"".sql"'],
    'Double quotes in file passed to capture() should be escaped';

ok $exa->run_handle('FH'), 'Spool a "file handle"';
my $handles = shift @spool;
is_deeply \@spool, [$exa->exaplus],
    'exaplus command should be passed to spool()';
isa_ok $handles, 'ARRAY', 'Array ove handles should be passed to spool';
$fh = $handles->[0];
is join('', <$fh>), $exa->_script, 'First file handle should be script';
is $handles->[1], 'FH', 'Second should be the passed handle';

# Verify should go to capture unless verosity is > 1.
$mock_exa->mock(_capture => sub {shift; @capture = @_ });
ok $exa->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, ['@"foo/bar.sql"'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $exa->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';

is_deeply \@capture, ['@"foo/bar.sql"'],
    'Verify file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_exa->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->(), 'foo'),
    qq{'year:' || CAST(EXTRACT(YEAR   FROM foo) AS SMALLINT)
        || ':month:'  || CAST(EXTRACT(MONTH  FROM foo) AS SMALLINT)
        || ':day:'    || CAST(EXTRACT(DAY    FROM foo) AS SMALLINT)
        || ':hour:'   || CAST(EXTRACT(HOUR   FROM foo) AS SMALLINT)
        || ':minute:' || CAST(EXTRACT(MINUTE FROM foo) AS SMALLINT)
        || ':second:' || FLOOR(CAST(EXTRACT(SECOND FROM foo) AS NUMERIC(9,4)))
        || ':time_zone:UTC'},
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

$dt = App::Sqitch::DateTime->new(
    year => 2017, month => 11, day => 06,
    hour => 11, minute => 47, second => 35, time_zone => 'Europe/Stockholm');
is $exa->_char2ts($dt), '2017-11-06 10:47:35',
    '_char2ts should present timestamp at UTC w/o tz identifier';

##############################################################################
# Test SQL helpers.
is $exa->_listagg_format, q{GROUP_CONCAT(%1$s ORDER BY %1$s SEPARATOR ' ')},
    'Should have _listagg_format';
is $exa->_ts_default, 'current_timestamp', 'Should have _ts_default';
is $exa->_regex_op, 'REGEXP_LIKE', 'Should have _regex_op';
is $exa->_simple_from, ' FROM dual', 'Should have _simple_from';
is $exa->_limit_default, '18446744073709551611', 'Should have _limit_default';

DBI: {
    local *DBI::errstr;
    ok !$exa->_no_table_error, 'Should have no table error';
    ok !$exa->_no_column_error, 'Should have no column error';
    $DBI::errstr = 'object foo not found';
    ok $exa->_no_table_error, 'Should now have table error';
    ok $exa->_no_column_error, 'Should now have no column error';
    ok !$exa->_unique_error, 'Unique constraints not supported by Exasol';
}

is_deeply [$exa->_limit_offset(8, 4)],
    [['LIMIT 8', 'OFFSET 4'], []],
    'Should get limit and offset';
is_deeply [$exa->_limit_offset(0, 2)],
    [['LIMIT 18446744073709551611', 'OFFSET 2'], []],
    'Should get limit and offset when offset only';
is_deeply [$exa->_limit_offset(12, 0)], [['LIMIT 12'], []],
    'Should get only limit with 0 offset';
is_deeply [$exa->_limit_offset(12)], [['LIMIT 12'], []],
    'Should get only limit with noa offset';
is_deeply [$exa->_limit_offset(0, 0)], [[], []],
    'Should get no limit or offset for 0s';
is_deeply [$exa->_limit_offset()], [[], []],
    'Should get no limit or offset for no args';

is_deeply [$exa->_regex_expr('corn', 'Obama$')],
    ['corn REGEXP_LIKE ?', '.*Obama$'],
    'Should use regexp_like and prepend wildcard to regex';
is_deeply [$exa->_regex_expr('corn', '^Obama')],
    ['corn REGEXP_LIKE ?', '^Obama.*'],
    'Should use regexp_like and append wildcard to regex';
is_deeply [$exa->_regex_expr('corn', '^Obama$')],
    ['corn REGEXP_LIKE ?', '^Obama$'],
    'Should not chande regex with both anchors';
is_deeply [$exa->_regex_expr('corn', 'Obama')],
    ['corn REGEXP_LIKE ?', '.*Obama.*'],
    'Should append wildcards to both ends without anchors';

# Make sure we have templates.
DBIEngineTest->test_templates_for($exa->key);

##############################################################################
# Can we do live tests?
my $dbh;
my $id = DBIEngineTest->randstr;
my ($reg1, $reg2) = map { $_ . $id } qw(sqitch sqitchtest);
END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    $dbh->{RaiseError} = 0;
    $dbh->{PrintError} = 1;
    $dbh->do("DROP SCHEMA $_ CASCADE") for ($reg1, $reg2);
}

$uri = URI->new(
    $ENV{SQITCH_TEST_EXASOL_URI} ||
    $ENV{EXA_URI} ||
    'db:exasol://dbadmin:password@localhost/dbadmin'
);
my $err;
for my $i (1..30) {
    $err = try {
        $exa->use_driver;
        $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
            PrintError  => 0,
            RaiseError  => 0,
            AutoCommit  => 1,
            HandleError => $exa->error_handler,
        });
        undef;
    } catch {
        $_;
    };

    # Sleep if it failed but Exasol is still starting up.
    last unless $err && ($DBI::state || '') eq 'HY000';
    sleep 1 if $i < 30;
}


DBIEngineTest->run(
    class             => $CLASS,
    target_params     => [ uri => $uri, registry => $reg1 ],
    alt_target_params => [ uri => $uri, registry => $reg2 ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have exaplus and can connect to the database.
        $self->sqitch->probe( $self->client, '-version' );
        $self->_capture('SELECT 1 FROM dual;');
    },
    engine_err_regex  => qr/\[Exasol\]\[Exasol(?:ution)? Driver\]syntax error/i,
    init_error        => __x(
        'Sqitch already initialized',
        schema => $reg2,
    ),
    add_second_format => q{%s + interval '1' second},
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            uc($reg2), 'The Sqitch schema should be the current schema';
    },
    no_unique => 1,
);

done_testing;
