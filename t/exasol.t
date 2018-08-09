#!/usr/bin/perl -w

# To test against a live Exasol database, you must set the EXA_URI environment variable.
# this is a stanard URI::db URI, and should look something like this:
#
#     export EXA_URI=db:exasol://dbadmin:password@localhost:5433/dbadmin?Driver=Exasol
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

my $CLASS;

delete $ENV{"VSQL_$_"} for qw(USER PASSWORD DATABASE HOST PORT);

BEGIN {
    $CLASS = 'App::Sqitch::Engine::exasol';
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

my $uri = URI::db->new('db:exasol:');
my $sqitch = App::Sqitch->new(options => { engine => 'exasol' });
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

my $client = 'exaplus' . ($^O eq 'MSWin32' ? '.exe' : '');
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
my %config = (
    'engine.exasol.client'   => '/path/to/exaplus',
    'engine.exasol.target'   => 'db:exasol://me:myself@localhost:4444',
    'engine.exasol.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

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
# Now make sure that (deprecated?) Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    options => {
        engine     => 'exasol',
        client     => '/some/other/exaplus',
    },
);

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $exa = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a exasol with sqitch with options';

is $exa->client, '/some/other/exaplus', 'client should be as optioned';
is_deeply [$exa->exaplus], [qw(
    /some/other/exaplus
    -u me
    -p myself
    -c localhost:4444
), @std_opts], 'exaplus command should be as optioned';

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

# Make sure double-quotes are escaped.
WIN32: {
    $file = $tmpdir->file('"foo$bar".sql');
    my $mock_file = Test::MockModule->new(ref $file);
    # Windows doesn't like the quotation marks, so prevent it from writing.
    $mock_file->mock(copy_to => 1) if $^O eq 'MSWin32';
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
$mock_config->unmock_all;
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
# Can we do live tests?
my $dbh;
END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    $dbh->{RaiseError} = 0;
    $dbh->{PrintError} = 1;
    $dbh->do($_) for (
        'DROP SCHEMA sqitch CASCADE',
        'DROP SCHEMA sqitchtest CASCADE',
    );
}

$uri = URI->new($ENV{EXA_URI} || 'db:dbadmin:password@localhost/dbadmin');
my $err = try {
    $exa->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [options => {
        engine    => 'exasol',
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
    }],
    target_params     => [ uri => $uri ],
    alt_target_params => [ uri => $uri, registry => 'sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have exaplus and can connect to the database.
        $self->sqitch->probe( $self->client, '-version' );
        $self->_capture('SELECT 1 FROM dual;');
    },
    engine_err_regex  => qr/\[EXASOL\]\[EXASolution driver\]syntax error/,
    init_error        => __x(
        'Sqitch already initialized',
        schema => 'sqitchtest',
    ),
    add_second_format => q{%s + interval '1' second},
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            'SQITCHTEST', 'The Sqitch schema should be the current schema';
    },
);

done_testing;
