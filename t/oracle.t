#!/usr/bin/perl -w

# Environment variables required to test:
#
# *   `SQITCH_TEST_ORACLE_URI`: A `db:oracle:` URI to connnect to the Oracle
#     database.
# *   `SQITCH_TEST_ALT_ORACLE_REGISTRY`: A different Oracle username to use as
#     an alternate registry schema. The user in `SQITCH_TEST_ORACLE_URI` must
#     have permission to write to this user's schema.
# *   `TWO_TASK`: If connecting to a pluggable database, you must also use the
#     TWO_TASK environment variable.
#
# ## Prerequisites
#
# Sqitch requires local access to the [Oracle Instant
# Client](https://www.oracle.com/database/technologies/instant-client/downloads.html),
# specifically the Basic, SQL*Plus, and SDK packages. Unpack them into a
# directory and set `ORACLE_HOME` and `LD_LIBRARY_PATH` to point to that
# directory, and add it to the Path. Then install DBD::Oracle.
#
# ## Oracle-XE Docker Image
#
# The simplest way to the Sqitch Oracle engine is with the
# [gvenzl/oracle-xe](https://hub.docker.com/r/gvenzl/oracle-xe) docker image.
# See `.github/workflows/oracle.yml` for an example. But essentially, start it
# like so:
#
# docker run -d -p 1521:1521 -e ORACLE_PASSWORD=oracle gvenzl/oracle-xe:18-slim
#
# Then you can configure connection like so:
#
#     export SQITCH_TEST_ORACLE_URI=db:oracle://system:oracle@localhost/XE
#     export SQITCH_TEST_ALT_ORACLE_REGISTRY=gsmuser
#     prove -lv t/oracle.t
#
# The `gsmuser` schema already exists in the `18-slim` image, so it should just
# work. You can create another user (and schema), though on Oracle 12 and later
# it will only be created in the XEPDB1 pluggable database. Pass the `APP_USER`
# and `APP_USER_PASSWORD` variables to `docker run` like so:
#
# docker run -d -p 1521:1521 \
#   -e ORACLE_PASSWORD=oracle \
#   -e APP_USER=sqitch \
#   -e APP_USER_PASSWORD=oracle \
#   gvenzl/oracle-xe:18-slim
#
# Then use the `TWO_TASK` environment variable to complete the connection
# (connecting to a pluggable database cannot be done purely by the connnection
# URI; see [oci-oracle-xe#46](https://github.com/gvenzl/oci-oracle-xe/issues/46)
# and [DBD::Oracle#131](https://github.com/perl5-dbi/DBD-Oracle/issues/131) for
# details):
#
#     export SQITCH_TEST_ORACLE_URI=db:oracle://system:oracle@/
#     export TWO_TASK=localhost/XEPDB1
#     export SQITCH_TEST_ALT_ORACLE_REGISTRY=sqitch
#     prove -lv t/oracle.t
#
# ## Developer Days VM
#
# Tests can also be run against the Developer Days VM with a bit of
# configuration. Download the VM from:
#
#   https://www.oracle.com/database/technologies/databaseappdev-vm.html
#
# Once the VM is imported into VirtualBox and started, login with the username
# "oracle" and the password "oracle". Then, in VirtualBox, go to Settings ->
# Network, select the NAT adapter, and add two port forwarding rules
# (https://barrymcgillin.blogspot.com/2011/12/using-oracle-developer-days-virtualbox.html):
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
# If this fails with either of these errors:
#
#    ORA-01017: invalid username/password; logon denied ORA-21561: OID
#    generation failed
#
# Make sure that your computer's hostname is on the localhost line of /etc/hosts
# (https://sourceforge.net/p/tora/discussion/52737/thread/f68b89ad/):
#
#     > hostname
#     stickywicket
#     > grep 127 /etc/hosts
#     127.0.0.1    localhost stickywicket
#
# Once connected, execute this SQL to create the user and give it access:
#
#     CREATE USER sqitchtest IDENTIFIED BY oracle;
#     GRANT ALL PRIVILEGES TO sqitchtest;
#
# The tests can use the existing "oe" user for the altnerate schema, so now the
# test can be run with:
#
#     export SQITCH_TEST_ORACLE_URI=db:oracle://sqitchtest:oracle@localhost/ORCL
#     export SQITCH_TEST_ALT_ORACLE_REGISTRY=oe
#     prove -lv t/oracle.t

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
use App::Sqitch::Target;
use App::Sqitch::Plan;
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::oracle';
    require_ok $CLASS or die;
    delete $ENV{ORACLE_HOME};
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $config = TestConfig->new('core.engine' => 'oracle');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
isa_ok my $ora = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $ora->key, 'oracle', 'Key should be "oracle"';
is $ora->name, 'Oracle', 'Name should be "Oracle"';

my $client = 'sqlplus' . (App::Sqitch::ISWIN ? '.exe' : '');
is $ora->client, $client, 'client should default to sqlplus';
ORACLE_HOME: {
    my $iswin = App::Sqitch::ISWIN || $^O eq 'cygwin';
    my $cli = 'sqlplus' . ($iswin ? '.exe' : '');

    # Start with no ORACLE_HOME.
    my $target = App::Sqitch::Target->new(sqitch => $sqitch);
    isa_ok my $ora = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
    is $ora->client, $cli, 'client should default to sqlplus';

    # Put client in ORACLE_HOME.
    my $tmpdir = tempdir(CLEANUP => 1);
    my $tmp = Path::Class::Dir->new("$tmpdir");
    my $sqlplus = $tmp->file($cli);
    $sqlplus->touch;
    chmod 0755, $sqlplus unless $iswin;

    local $ENV{ORACLE_HOME} = "$tmpdir";
    $target = App::Sqitch::Target->new(sqitch => $sqitch);
    isa_ok $ora = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
    is $ora->client, $sqlplus, 'client should use $ORACLE_HOME';

    # ORACLE_HOME/bin takes precedence.
    my $bin = Path::Class::Dir->new("$tmpdir", 'bin');
    $bin->mkpath;
    $sqlplus = $bin->file($cli);
    $sqlplus->touch;
    chmod 0755, $sqlplus unless $iswin;

    $target = App::Sqitch::Target->new(sqitch => $sqitch);
    isa_ok $ora = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
    is $ora->client, $sqlplus, 'client should use $ORACLE_HOME/bin';
}

is $ora->registry, '', 'registry default should be empty';
is $ora->uri, 'db:oracle:', 'Default URI should be "db:oracle"';

my $dest_uri = $ora->uri->clone;
$dest_uri->dbname(
        $ENV{TWO_TASK}
    || (App::Sqitch::ISWIN ? $ENV{LOCAL} : undef)
    || $ENV{ORACLE_SID}
);
is $ora->target->name, $ora->uri, 'Target name should be the uri stringified';
is $ora->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $ora->registry_destination, $ora->destination,
    'Registry target should be the same as target';

my @std_opts = qw(-S -L /nolog);
is_deeply [$ora->sqlplus], [$client, @std_opts],
    'sqlplus command should connect to /nolog';

is $ora->_script, join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'connect ',
    $ora->_registry_variable,
) ), '_script should work';

# Set up a target URI.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new('db:oracle://fred:derf@/blah')
);
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $ora->_script, join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'connect fred/"derf"@"blah"',
    $ora->_registry_variable,
) ), '_script should assemble connection string';

# Add a host name.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new('db:oracle://fred:derf@there/blah')
);
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $ora->_script('@foo'), join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'connect fred/"derf"@//there/"blah"',
    $ora->_registry_variable,
    '@foo',
) ), '_script should assemble connection string with host';

# Add a port and varibles.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new(
        'db:oracle://fred:derf%20%22derf%22@there:1345/blah%20%22blah%22'
    ),
);
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
ok $ora->set_variables(foo => 'baz', whu => 'hi there', yo => q{"stellar"}),
    'Set some variables';

is $ora->_script, join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'DEFINE foo="baz"',
    'DEFINE whu="hi there"',
    'DEFINE yo="""stellar"""',
    'connect fred/"derf ""derf"""@//there:1345/"blah ""blah"""',
    $ora->_registry_variable,
) ), '_script should assemble connection string with host, port, and vars';

# Try a URI with nothing but the database name.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new('db:oracle:secure_user_tns.tpg'),
);
like $target->uri->dbi_dsn, qr{^dbi:Oracle:(?:service_name=)?secure_user_tns\.tpg$},
    'Database-only URI should produce proper DSN';
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
is $ora->_script('@foo'), join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'connect /@"secure_user_tns.tpg"',
    $ora->_registry_variable,
    '@foo',
) ), '_script should assemble connection string with just dbname';

# Try a URI with double slash, but otherwise just the db name.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new('db:oracle://:@/wallet_tns_name'),
);
like $target->uri->dbi_dsn, qr{dbi:Oracle:(?:service_name=)?wallet_tns_name$},
    'Database and double-slash URI should produce proper DSN';
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
is $ora->_script('@foo'), join( "\n" => (
    'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF VERIFY OFF',
    'WHENEVER OSERROR EXIT 9;',
    'WHENEVER SQLERROR EXIT 4;',
    'connect /@"wallet_tns_name"',
    $ora->_registry_variable,
    '@foo',
) ), '_script should assemble connection string with double-slash and dbname';

##############################################################################
# Test other configs for the destination.
$target = App::Sqitch::Target->new(sqitch => $sqitch);
ENV: {
    # Make sure we override system-set vars.
    local $ENV{TWO_TASK};
    local $ENV{ORACLE_SID};
    for my $env (qw(TWO_TASK ORACLE_SID)) {
        my $ora = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = '$ENV=whatever';
        is $ora->target->name, "db:oracle:", "Target name should not read \$$env";
        is $ora->destination, "db:oracle:\$ENV=whatever", "Destination should read \$$env";
        is $ora->registry_destination, $ora->destination,
           'Registry destination should be the same as destination';
    }

    $ENV{TWO_TASK} = 'mydb';
    $ora = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $ora->target->name, 'db:oracle:', 'Target should be the default';
    is $ora->destination, 'db:oracle:mydb',
        'Destination should prefer $TWO_TASK to username';
    is $ora->registry_destination, $ora->destination,
        'Registry destination should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
$config->update(
    'engine.oracle.client'   => '/path/to/sqlplus',
    'engine.oracle.target'   => 'db:oracle://bob:hi@db.net:12/howdy',
    'engine.oracle.registry' => 'meta',
);
$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ora = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another ora';

is $ora->client, '/path/to/sqlplus', 'client should be as configured';
is $ora->uri->as_string, 'db:oracle://bob:hi@db.net:12/howdy',
    'DB URI should be as configured';
like $ora->target->name, qr{^db:oracle://bob:?\@db\.net:12/howdy$},
    'Target name should be the passwordless URI stringified';
like $ora->destination, qr{^db:oracle://bob:?\@db\.net:12/howdy$},
    'Destination should be the URI without the password';
is $ora->registry_destination, $ora->destination,
    'registry_destination should replace be the same URI';
is $ora->registry, 'meta', 'registry should be as configured';
is_deeply [$ora->sqlplus], ['/path/to/sqlplus', @std_opts],
    'sqlplus command should be configured';

$config->update(
    'engine.oracle.client'   => '/path/to/sqlplus',
    'engine.oracle.registry' => 'meta',
);

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ora = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create yet another ora';
is $ora->client, '/path/to/sqlplus', 'client should be as configured';
is $ora->registry, 'meta', 'registry should be as configured';
is_deeply [$ora->sqlplus], ['/path/to/sqlplus', @std_opts],
    'sqlplus command should be configured';

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
    [$ora->sqlplus], \$ora->_script(qw(foo bar baz)), [], [],
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

# Now the alias exists, make sure _file_for_script dies if it cannot remove it.
FILE: {
    my $mock_pcf = Test::MockModule->new('Path::Class::File');
    $mock_pcf->mock(remove => 0);
    throws_ok { $ora->_file_for_script($file) } 'App::Sqitch::X',
        'Should get an error on failure to delete the alias';
    is $@->ident, 'oracle', 'File deletion error ident should be "oracle"';
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
    is $ora->_file_for_script($file), $tmpdir->file('""foo_bar"".sql'),
        'File with special char and quotes should be aliased';
}

##############################################################################
# Test unexpeted datbase error in _cid().
$mock_ora->mock(dbh => sub { die 'OW' });
throws_ok { $ora->initialized } qr/OW/,
    'initialized() should rethrow unexpected DB error';
throws_ok { $ora->_cid } qr/OW/,
    '_cid should rethrow unexpected DB error';
$mock_ora->unmock('dbh');

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
$mock_ora->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->(), 'foo'), join( ' || ',
    q{to_char(foo AT TIME ZONE 'UTC', '"year":YYYY')},
    q{to_char(foo AT TIME ZONE 'UTC', ':"month":MM')},
    q{to_char(foo AT TIME ZONE 'UTC', ':"day":DD')},
    q{to_char(foo AT TIME ZONE 'UTC', ':"hour":HH24')},
    q{to_char(foo AT TIME ZONE 'UTC', ':"minute":MI')},
    q{to_char(foo AT TIME ZONE 'UTC', ':"second":SS')},
    q{':time_zone:UTC'},
), '_ts2char_format should work';

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
is $CLASS->_char2ts($dt),
    join(' ', $dt->ymd('-'), $dt->hms(':'), $dt->time_zone->name),
    'Should have _char2ts';

##############################################################################
# Test SQL helpers.
is $ora->_listagg_format, q{CAST(COLLECT(CAST(%s AS VARCHAR2(512))) AS sqitch_array)},
    'Should have _listagg_format';
is $ora->_regex_op, 'REGEXP_LIKE(%s, ?)', 'Should have _regex_op';
is $ora->_simple_from, ' FROM dual', 'Should have _simple_from';
is $ora->_limit_default, undef, 'Should have _limit_default';
is $ora->_ts_default, 'current_timestamp', 'Should have _ts_default';
is $ora->_can_limit, 0, 'Should have _can_limit false';

is $ora->_multi_values(1, 'FOO'), 'SELECT FOO FROM dual',
    'Should get single expression from _multi_values';
is $ora->_multi_values(2, 'LOWER(?)'),
    "SELECT LOWER(?) FROM dual\nUNION ALL SELECT LOWER(?) FROM dual",
    'Should get double expression from _multi_values';
is $ora->_multi_values(4, 'X'),
    "SELECT X FROM dual\nUNION ALL SELECT X FROM dual\nUNION ALL SELECT X FROM dual\nUNION ALL SELECT X FROM dual",
    'Should get quadrupal expression from _multi_values';

DBI: {
    local *DBI::err;
    ok !$ora->_no_table_error, 'Should have no table error';
    ok !$ora->_no_column_error, 'Should have no column error';

    $DBI::err = 942;
    ok $ora->_no_table_error, 'Should now have table error';
    ok !$ora->_no_column_error, 'Still should have no column error';

    $DBI::err = 904;
    ok !$ora->_no_table_error, 'Should again have no table error';
    ok $ora->_no_column_error, 'Should now have no column error';
}

# Test _log_tags_param.
my $plan = App::Sqitch::Plan->new(
    sqitch => $sqitch,
    target => $target,
    'project' => 'oracle',
);
my $change = App::Sqitch::Plan::Change->new(
    name => 'oracle_test',
    plan => $plan,
);
my @tags = map {
    App::Sqitch::Plan::Tag->new(
        plan   => $plan,
        name   => $_,
        change => $change,
    )
} qw(xxx yyy zzz);
$change->add_tag($_) for @tags;
is_deeply $ora->_log_tags_param($change), [qw(@xxx @yyy @zzz)],
    '_log_tags_param should format tags';

# Test _log_requires_param.
my @req = map {
    App::Sqitch::Plan::Depend->new(
        %{ App::Sqitch::Plan::Depend->parse($_) },
        plan => $plan,
    )
} qw(aaa bbb ccc);

my $mock_change = Test::MockModule->new(ref $change);
$mock_change->mock(requires => sub { @req });
is_deeply $ora->_log_requires_param($change), [qw(aaa bbb ccc)],
    '_log_requires_param should format prereqs';

# Test _log_conflicts_param.
$mock_change->mock(conflicts => sub { @req });
is_deeply $ora->_log_conflicts_param($change), [qw(aaa bbb ccc)],
    '_log_conflicts_param should format prereqs';

$mock_change->unmock_all;

##############################################################################
# Test _change_id_in()
can_ok $CLASS, qw(_change_id_in);
my $change_id_in = $CLASS->can('_change_id_in');
is $change_id_in->(0), '', 'Should get empty string for 0 change IDs';
is $change_id_in->(1), 'change_id IN (?)',
    'Should get single param for 1 change ID';
is $change_id_in->(3), 'change_id IN (?, ?, ?)',
    'Should get 3 params for 3 change IDs';
for my $count (10, 32, 50, 200, 250) {
    is $change_id_in->($count),
        'change_id IN (' . join(', ' => ('?') x $count) . ')',
        "Should get $count params for $count change IDs";
}

# Make sure we get multiple IN clauses for over 250 IDs.
my $in_group = 'change_id IN (' . join(', ' => ('?') x 250) . ')';
is $change_id_in->(251), "$in_group OR change_id IN (?)",
    'Should get 250 and 1 groups for 251 IDs';
is $change_id_in->(253), "$in_group OR change_id IN (?, ?, ?)",
    'Should get 250 and 3 groups for 253 IDs';
is $change_id_in->(502), "$in_group OR $in_group OR change_id IN (?, ?)",
    'Should get 250, 240, and 2 groups for 503 IDs';
is $change_id_in->(1042), join(
    ' OR ', $in_group, $in_group, $in_group, $in_group,
    'change_id IN (' . join(', ' => ('?') x 42) . ')'
), 'Should get 4 x 250 and 42 groups for 1042 IDs';

# Make sure we have templates.
DBIEngineTest->test_templates_for($ora->key);

##############################################################################
# Can we do live tests?
if (App::Sqitch::ISWIN && eval { require Win32::API }) {
    # Call kernel32.SetErrorMode(SEM_FAILCRITICALERRORS):
    # "The system does not display the critical-error-handler message box.
    # Instead, the system sends the error to the calling process." and
    # "A child process inherits the error mode of its parent process."
    my $SetErrorMode = Win32::API->new('kernel32', 'SetErrorMode', 'I', 'I');
    my $SEM_FAILCRITICALERRORS = 0x0001;
    $SetErrorMode->Call($SEM_FAILCRITICALERRORS);
}
my $alt_reg = $ENV{SQITCH_TEST_ALT_ORACLE_REGISTRY} || 'oe';
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
        'DROP TABLE events',
        'DROP TABLE dependencies',
        'DROP TABLE tags',
        'DROP TABLE changes',
        'DROP TABLE projects',
        'DROP TABLE releases',
        'DROP TYPE  sqitch_array',
        "DROP TABLE $alt_reg.events",
        "DROP TABLE $alt_reg.dependencies",
        "DROP TABLE $alt_reg.tags",
        "DROP TABLE $alt_reg.changes",
        "DROP TABLE $alt_reg.projects",
        "DROP TABLE $alt_reg.releases",
        "DROP TYPE  $alt_reg.sqitch_array",
    );
    $dbh->disconnect;
}

my $uri = $ENV{SQITCH_TEST_ORACLE_URI} ? URI->new($ENV{SQITCH_TEST_ORACLE_URI}) : do {
    my $uri = URI->new('db:oracle:');
    $uri->user($ENV{ORAUSER} || 'scott');
    $uri->password($ENV{ORAPASS} || 'tiger');
    $uri;
};

my $err = try {
    $ora->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError  => 0,
        RaiseError  => 0,
        AutoCommit  => 1,
        HandleError => $ora->error_handler,
    });
    undef;
} catch {
    $_;
};

DBIEngineTest->run(
    class             => $CLASS,
    version_query     => q{SELECT * FROM v$version WHERE banner LIKE 'Oracle%'},
    target_params     => [ uri => $uri ],
    alt_target_params => [ uri => $uri, registry => $alt_reg ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;

        #####
        ## Uncomment to find another user/schema to use for the alternate
        # schema in .github/workflows/oracle.yml.
        # my $dbh = $self->dbh;
        # for my $u (@{ $dbh->selectcol_arrayref('SELECT USERNAME FROM all_users') }) {
        #     my $result = 'success';
        #     try {
        #         $dbh->do("CREATE TABLE $u.try(id FLOAT)");
        #         $dbh->do("INSERT INTO $u.try VALUES(?)", undef, 1.0);
        #     } catch {
        #         $result = 'fail';
        #     };
        #     Test::More::diag("$u: $result");
        # }

        # Make sure we have sqlplus and can connect to the database.
        $self->sqitch->probe( $self->client, '-v' );
        my $v = $self->sqitch->capture( $self->client, '-v' );
        $v =~ s/\n+/ /gsx; $v =~ s/^\s+//;
        say "# Detected $v";
        $self->_capture('SELECT 1 FROM dual;');
    },
    engine_err_regex  => qr/^ORA-00925: /,
    init_error        => __ 'Sqitch already initialized',
    add_second_format => q{%s + interval '1' second},
);

done_testing;
