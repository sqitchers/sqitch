#!/usr/bin/perl -w

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

delete $ENV{"VSQL_$_"} for qw(USER PASSWORD DATABASE HOST PORT);

BEGIN {
    $CLASS = 'App::Sqitch::Engine::vertica';
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

my $sqitch = App::Sqitch->new(_engine => 'vertica');
isa_ok my $vta = $CLASS->new(sqitch => $sqitch), $CLASS;

my $uri = URI::db->new('db:vertica:');
my $client = 'vsql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $vta->client, $client, 'client should default to vsql';
is $vta->registry, 'sqitch', 'registry default should be "sqitch"';
is $vta->uri, $uri, 'DB URI should be "db:vertica:"';
my $dest_uri = $uri->clone;
$dest_uri->dbname($ENV{VERTICADATABASE} || $ENV{VERTICAUSER} || $sqitch->sysuser);
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
is_deeply [$vta->vsql], [$client, @std_opts],
    'vsql command should be std opts-only';

isa_ok $vta = $CLASS->new(sqitch => $sqitch), $CLASS;
ok $vta->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$vta->vsql], [
    $client,
    '--set' => 'foo=baz',
    '--set' => 'whu=hi there',
    '--set' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to vsql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{VERTICADATABASE};
    local $ENV{VERTICAUSER};
    for my $env (qw(VERTICADATABASE VERTICAUSER)) {
        my $vta = $CLASS->new(sqitch => $sqitch);
        local $ENV{$env} = "\$ENV=whatever";
        is $vta->target, "db:vertica:", "Target should not read \$$env";
        is $vta->registry_destination, $vta->destination,
            'Meta target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $vta = $CLASS->new(sqitch => $sqitch);
    is $vta->target, 'db:vertica:', 'Target should not fall back on sysuser';
    is $vta->registry_destination, $vta->destination,
        'Meta target should be the same as destination';

    $ENV{VERTICADATABASE} = 'mydb';
    $vta = $CLASS->new(sqitch => $sqitch, username => 'hi');
    is $vta->target, 'db:vertica:',  'Target should be the default';
    is $vta->registry_destination, $vta->destination,
        'Meta target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.vertica.client'   => '/path/to/vsql',
    'core.vertica.target'   => 'db:vertica://localhost/try',
    'core.vertica.username' => 'freddy',
    'core.vertica.password' => 's3cr3t',
    'core.vertica.db_name'  => 'widgets',
    'core.vertica.host'     => 'db.example.com',
    'core.vertica.port'     => 1234,
    'core.vertica.registry' => 'meta',
);
$std_opts[-1] = 'registry=meta';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

ok $vta = $CLASS->new(sqitch => $sqitch), 'Create another vertica';
is $vta->client, '/path/to/vsql', 'client should be as configured';
is $vta->uri->as_string, 'db:vertica://localhost/try',
    'uri should be as configured';
is $vta->registry, 'meta', 'registry should be as configured';
is_deeply [$vta->vsql], [qw(
    /path/to/vsql
    --dbname   try
    --host     localhost
), @std_opts], 'vsql command should be configured from URI config';

##############################################################################
# Try deprecated config.
%config = (
    'core.vertica.client'        => '/path/to/vsql',
    'core.vertica.username'      => 'freddy',
    'core.vertica.password'      => 's3cr3t',
    'core.vertica.db_name'       => 'widgets',
    'core.vertica.host'          => 'db.example.com',
    'core.vertica.port'          => 1234,
    'core.vertica.sqitch_schema' => 'meta',
);
ok $vta = $CLASS->new(sqitch => $sqitch), 'Create yet another vertica';
is $vta->uri->as_string, 'db:vertica://freddy:s3cr3t@db.example.com:1234/widgets',
    'DB URI should be derived from deprecated config vars';
is $vta->target, $vta->uri->as_string, 'target should be the URI';
like $vta->destination, qr{^db:vertica://freddy:?\@db\.example\.com:1234/widgets$},
    'destination should be the URI without the password';
is $vta->registry_destination, $vta->destination,
    'registry_destination should default be the URI';

##############################################################################
# Now make sure that (deprecated?) Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    _engine     => 'vertica',
    db_client   => '/some/other/vsql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $vta = $CLASS->new(sqitch => $sqitch), 'Create a vertica with sqitch with options';

is $vta->client, '/some/other/vsql', 'client should be as optioned';
is $vta->uri->as_string, 'db:vertica://anna:s3cr3t@foo.com:98760/widgets_dev',
    'uri should be as configured';
is $vta->target, $vta->uri->as_string, 'target should be the URI stringified';
like $vta->destination, qr{^db:vertica://anna:?\@foo\.com:98760/widgets_dev$},
    'destination should be the URI without the password';
is $vta->registry_destination, $vta->destination,
    'registry_destination should be the same as destination';
is $vta->registry, 'meta', 'registry should still be as configured';
is_deeply [$vta->vsql], [qw(
    /some/other/vsql
    --username anna
    --dbname   widgets_dev
    --host     foo.com
    --port     98760
), @std_opts], 'vsql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $vta, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
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
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{VSQL_PASSWORD}, $exp_pass, qq{VSQL_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{VSQL_PASSWORD}, 'VSQL_PASSWORD should not exist';
    }
});

$exp_pass = 's3cr3t';
ok $vta->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $vta->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $vta->vsql],
    'Command should be passed to spool()';

ok $vta->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$vta->vsql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Remove the password.
delete $config{'core.vertica.password'};
ok $vta = $CLASS->new(sqitch => $sqitch), 'Create a vertica with sqitch with no pw';
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
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char'), "$CLASS->can('_ts2char')";
is $ts2char->('foo'),
    q{to_char(foo AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')},
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

$uri = URI->new($ENV{VSQL_URI} || 'db:dbadmin:password@localhost/dbadmin');
my $err = try {
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

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        _engine   => 'vertica',
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ uri => $uri ],
    alt_engine_params => [ uri => $uri, registry => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have sqlplus and can connect to the database.
        $self->sqitch->probe( $self->client, '--version' );
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
