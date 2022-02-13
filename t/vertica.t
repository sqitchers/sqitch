#!/usr/bin/perl -w

# To test against a live Vertica database, you must set the SQITCH_TEST_VSQL_URI
# environment variable. this is a stanard URI::db URI, and should look something
# like this:
#
#     export SQITCH_TEST_VSQL_URI=db:vertica://dbadmin:password@localhost:5433/dbadmin?Driver=Vertica
#
# Note that it must include the `?Driver=$driver` bit so that DBD::ODBC loads
# the proper driver.

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
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

delete $ENV{"VSQL_$_"} for qw(USER PASSWORD DATABASE HOST PORT);

BEGIN {
    $CLASS = 'App::Sqitch::Engine::vertica';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:vertica:');
my $config = TestConfig->new('core.engine' => 'vertica');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $vta = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $vta->key, 'vertica', 'Key should be "vertica"';
is $vta->name, 'Vertica', 'Name should be "Vertica"';

my $client = 'vsql' . (App::Sqitch::ISWIN ? '.exe' : '');
is $vta->client, $client, 'client should default to vsql';
is $vta->registry, 'sqitch', 'registry default should be "sqitch"';
is $vta->uri, $uri, 'DB URI should be "db:vertica:"';
my $dest_uri = $uri->clone;
$dest_uri->dbname($ENV{VSQL_DATABASE} || $ENV{VSQL_USER} || $sqitch->sysuser);
is $vta->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $vta->registry_destination, $vta->destination,
    'Registry destination should be the same as destination';

my @std_opts = (
    '--quiet',
    '--no-vsqlrc',
    '--no-align',
    '--tuples-only',
    '--set' => 'ON_ERROR_STOP=1',
    '--set' => 'registry=sqitch',
);
is_deeply [$vta->vsql], [$client, '--username', $sqitch->sysuser, @std_opts],
    'vsql command should be username and std opts-only';

isa_ok $vta = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
ok $vta->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$vta->vsql], [
    $client,
    '--username', $sqitch->sysuser,
    '--set' => 'foo=baz',
    '--set' => 'whu=hi there',
    '--set' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to vsql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{VSQL_DATABASE};
    local $ENV{VSQL_USER};
    local $ENV{VSQL_PASSWORD};
    for my $env (qw(VSQL_DATABASE VSQL_USER VSQL_PASSWORD)) {
        my $vta = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = "\$ENV=whatever";
        is $vta->target->name, "db:vertica:", "Target name should not read \$$env";
        is $vta->registry_destination, $vta->destination,
            'Registry target should be the same as destination';
        is $vta->username, $ENV{VSQL_USER} || $sqitch->sysuser,
            "Should have username when $env set";
        is $vta->password, $ENV{VSQL_PASSWORD},
            "Should have password when $env set";
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $vta = $CLASS->new(sqitch => $sqitch, target => $target);
    is $vta->target->name, 'db:vertica:',
        'Target name should not fall back on sysuser';
    is $vta->registry_destination, $vta->destination,
        'Registry target should be the same as destination';

    $ENV{VSQL_DATABASE} = 'mydb';
    $vta = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $vta->target->name, 'db:vertica:',  'Target name should be the default';
    is $vta->registry_destination, $vta->destination,
        'Registry target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
$config->update(
    'engine.vertica.client'   => '/path/to/vsql',
    'engine.vertica.target'   => 'db:vertica://localhost/try',
    'engine.vertica.registry' => 'meta',
);
$std_opts[-1] = 'registry=meta';

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $vta = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another vertica';
is $vta->client, '/path/to/vsql', 'client should be as configured';
is $vta->uri->as_string, 'db:vertica://localhost/try',
    'uri should be as configured';
is $vta->registry, 'meta', 'registry should be as configured';
is_deeply [$vta->vsql], [
    '/path/to/vsql',
    '--username', $sqitch->sysuser,
    '--dbname',   'try',
    '--host',     'localhost',
    @std_opts
], 'vsql command should be configured from URI config';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $vta, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{VSQL_PASSWORD}, $exp_pass, qq{VSQL_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{VSQL_PASSWORD}, 'VSQL_PASSWORD should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{VSQL_PASSWORD}, $exp_pass, qq{VSQL_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{VSQL_PASSWORD}, 'VSQL_PASSWORD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{VSQL_PASSWORD}, $exp_pass, qq{VSQL_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{VSQL_PASSWORD}, 'VSQL_PASSWORD should not exist';
    }
});

$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $vta->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $vta->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $vta->vsql],
    'Command should be passed to spool()';

ok $vta->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $vta = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a vertica with sqitch with no pw';
$exp_pass = undef;
ok $vta->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $vta->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $vta->vsql],
    'Command should be passed to spool() again';

ok $vta->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $vta->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$vta->vsql, '--file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $vta->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $vta->vsql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $vta->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$vta->vsql, '--file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $vta->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$vta->vsql, '--file', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->(), 'foo'),
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
        'DROP SCHEMA __sqitchtest CASCADE',
    );
}

$uri = URI->new(
    $ENV{SQITCH_TEST_VSQL_URI} ||
    $ENV{VSQL_URI} ||
    'db:vertica://dbadmin:password@localhost/dbadmin'
);

# Try to connect.
my $err;
for my $i (1..30) {
    $err = try {
        $vta->use_driver;
        $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
            PrintError => 0,
            RaiseError => 1,
            AutoCommit => 1,
        });
        undef;
    } catch {
        eval { $_->message } || $_;
    };
    # Sleep if it failed but Vertica is still starting up.
    # SQL-57V03: `failed: FATAL 4149:  Node startup/recovery in progress. Not yet ready to accept connections`
    # SQL-08001: `failed: [Vertica][DSI] An error occurred while attempting to retrieve the error message for key 'VConnectFailed' and component ID 101: Could not open error message files`
    last unless $err && (($DBI::state || '') eq '57V03' || $err =~ /VConnectFailed/);
    sleep 1 if $i < 30;
}

DBIEngineTest->run(
    class             => $CLASS,
    version_query     => 'SELECT version()',
    target_params     => [ uri => $uri ],
    alt_target_params => [ uri => $uri, registry => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have vsql and can connect to the database.
        my $version = $self->sqitch->capture( $self->client, '--version' );
        say "# Detected $version";
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/\bERROR \d+:/,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            '__sqitchtest', 'The Sqitch schema should be the current schema';
    },
);

done_testing;
