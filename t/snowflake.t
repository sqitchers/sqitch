#!/usr/bin/perl -w

# To test against a live Snowflake database, you must set the SNOWSQL_URI environment variable.
# this is a stanard URI::db URI, and should look something like this:
#
#     export SNOWSQL_URI=db:snowflake://dbadmin:password@localhost:5433/dbadmin?Driver=Snowflake
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

my $CLASS;

delete $ENV{"SNOWSQL_$_"} for qw(USER PASSWORD DATABASE HOST PORT);

BEGIN {
    $CLASS = 'App::Sqitch::Engine::snowflake';
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

my $uri = URI::db->new('db:snowflake:');
my $sqitch = App::Sqitch->new(options => { engine => 'snowflake' });
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $vta = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $vta->key, 'snowflake', 'Key should be "snowflake"';
is $vta->name, 'Snowflake', 'Name should be "Snowflake"';

my $client = 'snowsql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $vta->client, $client, 'client should default to snowsql';
is $vta->registry, 'sqitch', 'registry default should be "sqitch"';
is $vta->uri, $uri, 'DB URI should be "db:snowflake:"';
my $dest_uri = $uri->clone;
$dest_uri->dbname($ENV{SNOWFLAKEDATABASE} || $ENV{SNOWFLAKEUSER} || $sqitch->sysuser);
is $vta->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $vta->registry_destination, $vta->destination,
    'Registry destination should be the same as destination';

my @std_opts = (
    '--noup',
    '--option' => 'auto_completion=false',
    '--option' => 'echo=false',
    '--option' => 'execution_only=false',
    '--option' => 'friendly=false',
    '--option' => 'header=false',
    '--option' => 'exit_on_error=true',
    '--option' => 'output_format=plain',
    '--option' => 'paging=false',
    '--option' => 'timing=false',
    '--option' => 'wrap=false',
    '--option' => 'results=true',
    '--option' => 'rowset_size=1000',
    '--option' => 'syntax_style=default',
    '--option' => 'variable_substitution=true',
    '--variable' => 'registry=sqitch',
);
is_deeply [$vta->snowsql], [$client, @std_opts],
    'snowsql command should be std opts-only';

isa_ok $vta = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
ok $vta->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$vta->snowsql], [
    $client,
    '--variable' => 'foo=baz',
    '--variable' => 'whu=hi there',
    '--variable' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to snowsql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{SNOWFLAKEDATABASE};
    local $ENV{SNOWFLAKEUSER};
    for my $env (qw(SNOWFLAKEDATABASE SNOWFLAKEUSER)) {
        my $vta = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = "\$ENV=whatever";
        is $vta->target->name, "db:snowflake:", "Target name should not read \$$env";
        is $vta->registry_destination, $vta->destination,
            'Meta target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $vta = $CLASS->new(sqitch => $sqitch, target => $target);
    is $vta->target->name, 'db:snowflake:',
        'Target name should not fall back on sysuser';
    is $vta->registry_destination, $vta->destination,
        'Meta target should be the same as destination';

    $ENV{SNOWFLAKEDATABASE} = 'mydb';
    $vta = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $vta->target->name, 'db:snowflake:',  'Target name should be the default';
    is $vta->registry_destination, $vta->destination,
        'Meta target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.snowflake.client'   => '/path/to/snowsql',
    'engine.snowflake.target'   => 'db:snowflake://localhost/try',
    'engine.snowflake.registry' => 'meta',
);
$std_opts[-1] = 'registry=meta';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $vta = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another snowflake';
is $vta->client, '/path/to/snowsql', 'client should be as configured';
is $vta->uri->as_string, 'db:snowflake://localhost/try',
    'uri should be as configured';
is $vta->registry, 'meta', 'registry should be as configured';
is_deeply [$vta->snowsql], [qw(
    /path/to/snowsql
    --dbname   try
    --host     localhost
), @std_opts], 'snowsql command should be configured from URI config';

##############################################################################
# Now make sure that (deprecated?) Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    options => {
        engine     => 'snowflake',
        client     => '/some/other/snowsql',
    },
);

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $vta = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a snowflake with sqitch with options';

is $vta->client, '/some/other/snowsql', 'client should be as optioned';
is_deeply [$vta->snowsql], [qw(
    /some/other/snowsql
    --dbname   try
    --host     localhost
), @std_opts], 'snowsql command should be as optioned';

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
        is $ENV{SNOWSQL_PWD}, $exp_pass, qq{SNOWSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{SNOWSQL_PWD}, 'SNOWSQL_PWD should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{SNOWSQL_PWD}, $exp_pass, qq{SNOWSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{SNOWSQL_PWD}, 'SNOWSQL_PWD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{SNOWSQL_PWD}, $exp_pass, qq{SNOWSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{SNOWSQL_PWD}, 'SNOWSQL_PWD should not exist';
    }
});

$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $vta->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$vta->snowsql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $vta->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $vta->snowsql],
    'Command should be passed to spool()';

ok $vta->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$vta->snowsql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $vta = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a snowflake with sqitch with no pw';
$exp_pass = undef;
ok $vta->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$vta->snowsql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $vta->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $vta->snowsql],
    'Command should be passed to spool() again';

ok $vta->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$vta->snowsql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $vta->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$vta->snowsql, '--filename', 'foo/bar.sql'],
    'File should be passed to run()';

ok $vta->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $vta->snowsql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
# ok $vta->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
# is_deeply \@capture, [$vta->snowsql, '--filename', 'foo/bar.sql'],
#     'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $vta->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$vta->snowsql, '--filename', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->(), 'foo'),
    q{to_varchar(CONVERT_TIMEZONE('UTC', foo), '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')},
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

$uri = URI->new($ENV{SNOWSQL_URI} || 'db:dbadmin:password@localhost/dbadmin');
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


done_testing;
