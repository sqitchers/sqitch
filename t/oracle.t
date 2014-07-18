#!/usr/bin/perl -w

# Environment variables required to test:
#
# * ORAUSER
# * ORAPASS
# * TWO_TASK
#
# Tests can be run against the Developer Days VM with a bit of configuration.
# Download the VM from:
#
#   http://www.oracle.com/technetwork/database/enterprise-edition/databaseappdev-vm-161299.html
#
# Once the VM is imported into VirtualBox and started, login with the username
# "oracle" and the password "oracle". Then, in VirtualBox, go to Settings ->
# Network, select the NAT adapter, and add two port forwarding rules
# (http://barrymcgillin.blogspot.com/2011/12/using-oracle-developer-days-virtualbox.html):
#
#   Host Port | Guest Port
#  -----------+------------
#        1521 |       1521
#        2222 |         22
#
# Then restart the VM. You should then be able to connect from your host with:
#
#     sqlplus sys/oracle@localhost/ORCL as sysdba
#
#
# If this fails with either of these errors:
#
#    ORA-01017: invalid username/password; logon denied
#    ORA-21561: OID generation failed
#
# Make sure that your computer's hostname is on the localhost line of
# /etc/hosts (http://sourceforge.net/p/tora/discussion/52737/thread/f68b89ad/):
#
#     > hostname
#     dwhee-ma-2944
#     > grep 127 /etc/hosts
#     127.0.0.1	localhost dwhee-ma-2944
#
# Once connected, execute this SQL to create the user and give it access:
#
#     CREATE USER sqitchtest IDENTIFIED BY oracle;
#     GRANT ALL PRIVILEGES TO sqitchtest;
#     CREATE USER oe IDENTIFIED BY oracle;
#     GRANT ALL PRIVILEGES TO oe;
#
# Now the tests can be run with:
#
# ORAUSER=sqitchtest ORAPASS=oracle TWO_TASK=localhost/ORCL prove -lv t/oracle.t

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
use lib 't/lib';
use DBIEngineTest;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::oracle';
    require_ok $CLASS or die;
    $ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.user';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.sys';
    #delete $ENV{ORACLE_HOME};
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new(_engine => 'oracle');
isa_ok my $ora = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'sqlplus' . ($^O eq 'MSWin32' ? '.exe' : '');
is $ora->client, $client, 'client should default to sqlplus';
ORACLE_HOME: {
    local $ENV{ORACLE_HOME} = '/foo/bar';
    isa_ok my $ora = $CLASS->new(sqitch => $sqitch), $CLASS;
    is $ora->client, Path::Class::file('/foo/bar', $client)->stringify,
        'client should use $ORACLE_HOME';
}

is $ora->registry, undef, 'registry default should be undefined';
is $ora->uri, 'db:oracle:', 'Default URI should be "db:oracle"';

my $dest_uri = $ora->uri->clone;
$dest_uri->dbname(
        $ENV{TWO_TASK}
    || ($^O eq 'MSWin32' ? $ENV{LOCAL} : undef)
    || $ENV{ORACLE_SID}
    || $sqitch->sysuser
);
is $ora->target, $ora->uri, 'Target should be the uri stringified';
is $ora->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $ora->registry_destination, $ora->destination,
    'Registry target should be the same as target';

my @std_opts = qw(-S -L /nolog);
is_deeply [$ora->sqlplus], [$client, @std_opts],
    'sqlplus command should connect to /nolog';

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect ',
) ), '_script should work';

# Set up username, password, and db_name.
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    uri  => URI::db->new('db:oracle://fred:derf@/blah')
), $CLASS;

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect fred/"derf"@"blah"',
) ), '_script should assemble connection string';

# Add a host name.
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    uri  => URI::db->new('db:oracle://fred:derf@there/blah')
), $CLASS;

is $ora->_script('@foo'), join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect fred/"derf"@//there/"blah"',
        '@foo',
) ), '_script should assemble connection string with host';

# Add a port and varibles.
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    uri => URI::db->new(
        'db:oracle://fred:derf%20%22derf%22@there:1345/blah%20%22blah%22'
    ),
), $CLASS;
ok $ora->set_variables(foo => 'baz', whu => 'hi there', yo => q{"stellar"}),
    'Set some variables';

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'DEFINE foo="baz"',
        'DEFINE whu="hi there"',
        'DEFINE yo="""stellar"""',
        'connect fred/"derf ""derf"""@//there:1345/"blah ""blah"""',
) ), '_script should assemble connection string with host, port, and vars';

##############################################################################
# Test other configs for the destination.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{TWO_TASK};
    local $ENV{ORACLE_SID};
    for my $env (qw(TWO_TASK ORACLE_SID)) {
        my $ora = $CLASS->new(sqitch => $sqitch);
        local $ENV{$env} = '$ENV=whatever';
        is $ora->target, "db:oracle:", "Target should not read \$$env";
        is $ora->destination, "db:oracle:\$ENV=whatever", "Destination should read \$$env";
        is $ora->registry_destination, $ora->destination,
           'Registry destination should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $ora = $CLASS->new(sqitch => $sqitch);
    is $ora->target, 'db:oracle:', 'Target should not fall back on sysuser';
    is $ora->destination, 'db:oracle:sysuser=whatever',
        'Destination should fall back on sysuser';
    is $ora->registry_destination, $ora->destination,
        'Registry destination should be the same as destination';

    $ENV{TWO_TASK} = 'mydb';
    $ora = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $ora->target, 'db:oracle:', 'Target should be the default';
    is $ora->destination, 'db:oracle:mydb',
        'Destination should prefer $TWO_TASK to username';
    is $ora->registry_destination, $ora->destination,
        'Registry destination should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.oracle.client'   => '/path/to/sqlplus',
    'core.oracle.target'   => 'db:oracle://bob:hi@db.net:12/howdy',
    'core.oracle.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $ora = $CLASS->new(sqitch => $sqitch), 'Create another ora';

is $ora->client, '/path/to/sqlplus', 'client should be as configured';
is $ora->uri->as_string, 'db:oracle://bob:hi@db.net:12/howdy',
    'DB URI should be as configured';
is $ora->target, $ora->uri->as_string, 'Target should be the URI stringified';
like $ora->destination, qr{^db:oracle://bob:?\@db\.net:12/howdy$},
    'Destination should be the URI without the password';
is $ora->registry_destination, $ora->destination,
    'registry_destination should replace be the same URI';
is $ora->registry, 'meta', 'registry should be as configured';
is_deeply [$ora->sqlplus], ['/path/to/sqlplus', @std_opts],
    'sqlplus command should be configured';

%config = (
    'core.oracle.client'   => '/path/to/sqlplus',
    'core.oracle.username' => 'freddy',
    'core.oracle.password' => 's3cr3t',
    'core.oracle.db_name'  => 'widgets',
    'core.oracle.host'     => 'db.example.com',
    'core.oracle.port'     => 1234,
    'core.oracle.registry' => 'meta',
);

ok $ora = $CLASS->new(sqitch => $sqitch), 'Create yet another ora';
is $ora->client, '/path/to/sqlplus', 'client should be as configured';
is $ora->uri->as_string, 'db:oracle://freddy:s3cr3t@db.example.com:1234/widgets',
    'DB URI should be constructed from old config variables';
is $ora->target, $ora->uri->as_string, 'Target should be the URI stringified';
like $ora->destination, qr{^db:oracle://freddy:?\@db\.example\.com:1234/widgets$},
    'Destination should be the URI without the password';
is $ora->registry_destination, $ora->destination,
    'registry_destination should be the same URI';
is $ora->registry, 'meta', 'registry should be as configured';
is_deeply [$ora->sqlplus], ['/path/to/sqlplus', @std_opts],
    'sqlplus command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    _engine     => 'oracle',
    db_client   => '/some/other/sqlplus',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $ora = $CLASS->new(sqitch => $sqitch), 'Create a ora with sqitch with options';

is $ora->client, '/some/other/sqlplus', 'client should be as optioned';
is $ora->uri->as_string, 'db:oracle://anna:s3cr3t@foo.com:98760/widgets_dev',
    'DB URI should have attributes overridden by options';
is $ora->target, $ora->uri->as_string, 'Target should be the URI stringified';
like $ora->destination, qr{^db:oracle://anna:?\@foo\.com:98760/widgets_dev$},
    'Destination should be the URI without the password';
is $ora->registry_destination, $ora->destination,
    'registry_destination should still be the same URI';
is $ora->registry, 'meta', 'registry should still be as configured';
is_deeply [$ora->sqlplus], ['/some/other/sqlplus', @std_opts],
    'sqlplus command should be as optioned';

##############################################################################
# Test _run() and _capture().
can_ok $ora, qw(_run _capture);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@capture, @spool);
$mock_sqitch->mock(spool   => sub { shift; @spool = @_ });
my $mock_run3 = Test::MockModule->new('IPC::Run3');
$mock_run3->mock(run3 => sub { @capture = @_ });

ok $ora->_run(qw(foo bar baz)), 'Call _run';
my $fh = shift @spool;
is_deeply \@spool, [$ora->sqlplus],
    'SQLPlus command should be passed to spool()';

is join('', <$fh> ), $ora->_script(qw(foo bar baz)),
    'The script should be spooled';

ok $ora->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [
    [$ora->sqlplus], \$ora->_script(qw(foo bar baz)), [], undef,
    { return_if_system_error => 1 },
], 'Command and script should be passed to run3()';

# Let's make sure that IPC::Run3 actually works as expected.
$mock_run3->unmock_all;
my $echo = Path::Class::file(qw(t echo.pl));
my $mock_ora = Test::MockModule->new($CLASS);
$mock_ora->mock(sqlplus => sub { $^X, $echo, qw(hi there) });

is join (', ' => $ora->_capture(qw(foo bar baz))), "hi there\n",
    '_capture should actually capture';

# Make it die.
my $die = Path::Class::file(qw(t die.pl));
$mock_ora->mock(sqlplus => sub { $^X, $die, qw(hi there) });
like capture_stderr {
    throws_ok {
        $ora->_capture('whatever'),
    } 'App::Sqitch::X', '_capture should die when sqlplus dies';
}, qr/^OMGWTF/, 'STDERR should be emitted by _capture';

##############################################################################
# Test _file_for_script().
can_ok $ora, '_file_for_script';
is $ora->_file_for_script(Path::Class::file 'foo'), 'foo',
    'File without special characters should be used directly';
is $ora->_file_for_script(Path::Class::file '"foo"'), '""foo""',
    'Double quotes should be SQL-escaped';

# Get the temp dir used by the engine.
ok my $tmpdir = $ora->tmpdir, 'Get temp dir';
isa_ok $tmpdir, 'Path::Class::Dir', 'Temp dir';

# Make sure a file with @ is aliased.
my $file = $tmpdir->file('foo@bar.sql');
$file->touch; # File must exist, because on Windows it gets copied.
is $ora->_file_for_script($file), $tmpdir->file('foo_bar.sql'),
    'File with special char should be aliased';

# Make sure double-quotes are escaped.
WIN32: {
    $file = $tmpdir->file('"foo$bar".sql');
    my $mock_file = Test::MockModule->new(ref $file);
    # Windows doesn't like the quotation marks, so prevent it from writing.
    $mock_file->mock(copy_to => 1) if $^O eq 'MSWin32';
    is $ora->_file_for_script($file), $tmpdir->file('""foo_bar"".sql'),
        'File with special char and quotes should be aliased';
}

##############################################################################
# Test file and handle running.
my @run;
$mock_ora->mock(_run => sub {shift; @run = @_ });
ok $ora->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, ['@"foo/bar.sql"'],
    'File should be passed to run()';

ok $ora->run_file('foo/"bar".sql'), 'Run foo/"bar".sql';
is_deeply \@run, ['@"foo/""bar"".sql"'],
    'Double quotes in file passed to run() should be escaped';

ok $ora->run_handle('FH'), 'Spool a "file handle"';
my $handles = shift @spool;
is_deeply \@spool, [$ora->sqlplus],
    'sqlplus command should be passed to spool()';
isa_ok $handles, 'ARRAY', 'Array ove handles should be passed to spool';
$fh = $handles->[0];
is join('', <$fh>), $ora->_script, 'First file handle should be script';
is $handles->[1], 'FH', 'Second should be the passed handle';

# Verify should go to capture unless verosity is > 1.
$mock_ora->mock(_capture => sub {shift; @capture = @_ });
ok $ora->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, ['@"foo/bar.sql"'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $ora->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, ['@"foo/bar.sql"'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;
$mock_ora->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char'), "$CLASS->can('_ts2char')";
is $ts2char->('foo'),
    q{to_char(foo AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')},
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
if ($^O eq 'MSWin32' && eval { require Win32::API}) {
    # Call kernel32.SetErrorMode(SEM_FAILCRITICALERRORS):
    # "The system does not display the critical-error-handler message box.
    # Instead, the system sends the error to the calling process." and
    # "A child process inherits the error mode of its parent process."
    my $SetErrorMode = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $SEM_FAILCRITICALERRORS = 0x0001;
    $SetErrorMode->Call($SEM_FAILCRITICALERRORS);
}
my $dbh;
END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    $dbh->{RaiseError} = 0;
    $dbh->{PrintError} = 1;
    my @tables = qw /events dependencies tags changes projects/;
    $dbh->do("DROP TABLE $_") for @tables;
    $dbh->do("DROP TABLE oe.$_") for @tables;
    $dbh->do("DROP TABLE sqitch_$_") for @tables;
    $dbh->do("DROP TYPE sqitch_array");
    $dbh->do("DROP TYPE oe.sqitch_array");
    $dbh->do("DROP TYPE sqitch_sqitch_array");
}

my $user = $ENV{ORAUSER} || 'scott';
my $pass = $ENV{ORAPASS} || 'tiger';
my $err = try {
    $ora->use_driver;
    my $dsn = 'dbi:Oracle:';
    $dbh = DBI->connect($dsn, $user, $pass, {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });
    undef;
} catch {
    eval { $_->message } || $_;
};

my $uri = URI->new('db:oracle:');
$uri->user($user);
$uri->password($pass);
# $uri->dbname( $ENV{TWO_TASK} || $ENV{LOCAL} || $ENV{ORACLE_SID} );
DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        _engine   => 'oracle',
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ uri => $uri, ], # use_registry_prefix => 1
    alt_engine_params => [ uri => $uri, registry => 'oe' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have sqlplus and can connect to the database.
        $self->sqitch->probe( $self->client, '-v' );
        $self->_capture('SELECT 1 FROM dual;');
    },
    engine_err_regex  => qr/^ORA-00925: /,
    init_error        => __ 'Sqitch already initialized',
    add_second_format => q{%s + interval '1' second},
);

done_testing;
