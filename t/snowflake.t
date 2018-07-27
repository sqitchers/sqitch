#!/usr/bin/perl -w

# To test against a live Snowflake database, you must set the SNOWSQL_URI environment variable.
# this is a stanard URI::db URI, and should look something like this:
#
#     export SNOWSQL_URI=db:snowflake://username:password@accountname/dbname?Driver=Snowflake&warehouse=sqitch
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
    $ENV{SNOWSQL_ACCOUNT}      = 'nonesuch';
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

# Disable config file parsing for the remainder of the tests.
my $mock_snow = Test::MockModule->new($CLASS);
$mock_snow->mock(_snowcfg => {});

isa_ok my $snow = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $snow->key, 'snowflake', 'Key should be "snowflake"';
is $snow->name, 'Snowflake', 'Name should be "Snowflake"';

my $client = 'snowsql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $snow->client, $client, 'client should default to snowsql';
is $snow->registry, 'sqitch', 'registry default should be "sqitch"';
is $snow->uri, $uri, 'DB URI should be filled in';
is $snow->destination, $uri->as_string,
    'Destination should fall back on environment variables';
is $snow->registry_destination, $snow->destination,
    'Registry destination should be the same as destination';

my @con_opts = (
    '--accountname' => $ENV{SNOWSQL_ACCOUNT},
    '--username' => $snow->username,
    '--dbname' => $uri->dbname,
);

my @std_opts = (
    '--noup',
    '--option' => 'auto_completion=false',
    '--option' => 'echo=false',
    '--option' => 'execution_only=false',
    '--option' => 'friendly=false',
    '--option' => 'header=false',
    '--option' => 'exit_on_error=true',
    '--option' => 'stop_on_error=true',
    '--option' => 'output_format=csv',
    '--option' => 'paging=false',
    '--option' => 'timing=false',
    '--option' => 'results=true',
    '--option' => 'wrap=false',
    '--option' => 'rowset_size=1000',
    '--option' => 'syntax_style=default',
    '--option' => 'variable_substitution=true',
    '--variable' => 'registry=sqitch',
    '--variable' => 'warehouse=' . $snow->warehouse,
);
is_deeply [$snow->snowsql], [$client, @con_opts, @std_opts],
    'snowsql command should be std opts-only';

isa_ok $snow = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;
ok $snow->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$snow->snowsql], [
    $client,
    @con_opts,
    '--variable' => 'foo=baz',
    '--variable' => 'whu=hi there',
    '--variable' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to snowsql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{SNOWSQL_DATABASE};
    local $ENV{SNOWSQL_USER};
    for my $env (qw(SNOWSQL_DATABASE SNOWSQL_USER)) {
        my $snow = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = "\$ENV=whatever";
        is $snow->target->name, "db:snowflake:", "Target name should not read \$$env";
        is $snow->registry_destination, $snow->destination,
            'Meta target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $snow = $CLASS->new(sqitch => $sqitch, target => $target);
    is $snow->target->name, 'db:snowflake:',
        'Target name should not fall back on sysuser';
    is $snow->registry_destination, $snow->destination,
        'Meta target should be the same as destination';

    $ENV{SNOWSQL_DATABASE} = 'mydb';
    $snow = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $snow->target->name, 'db:snowflake:',  'Target name should be the default';
    is $snow->registry_destination, $snow->destination,
        'Meta target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.snowflake.client'   => '/path/to/snowsql',
    'engine.snowflake.target'   => 'db:snowflake://fred@foo/try?warehouse=foo',
    'engine.snowflake.registry' => 'meta',
);
$std_opts[-3] = 'registry=meta';
$std_opts[-1] = 'warehouse=foo';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $snow = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another snowflake';
is $snow->client, '/path/to/snowsql', 'client should be as configured';
is $snow->uri->as_string,
    'db:snowflake://fred@foo.snowflakecomputing.com/try?warehouse=foo',
    'URI should be as configured with full domain name';
is $snow->registry, 'meta', 'registry should be as configured';
is_deeply [$snow->snowsql], [qw(
    /path/to/snowsql
    --accountname foo
    --username    fred
    --dbname      try
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
my $exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $snow = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a snowflake with sqitch with options';

is $snow->client, '/some/other/snowsql', 'client should be as optioned';
is_deeply [$snow->snowsql], [qw(
    /some/other/snowsql
    --accountname foo
    --username    fred
    --dbname      try
), @std_opts], 'snowsql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $snow, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
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
    return;
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

ok $snow->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@capture, [$snow->snowsql, qw(foo bar baz)],
    'Command should be passed to capture()';

ok $snow->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $snow->snowsql, $snow->_verbose_opts],
    'Command should be passed to spool()';

lives_ok { $snow->_capture(qw(foo bar baz)) } 'Call _capture';
is_deeply \@capture, [$snow->snowsql, $snow->_verbose_opts, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $snow = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a snowflake with sqitch with no pw';
$exp_pass = undef;
ok $snow->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@capture, [$snow->snowsql, qw(foo bar baz)],
    'Command should be passed to capture() again';

ok $snow->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $snow->snowsql, $snow->_verbose_opts],
    'Command should be passed to spool() again';

lives_ok { $snow->_capture(qw(foo bar baz)) } 'Call _capture again';
is_deeply \@capture, [$snow->snowsql, $snow->_verbose_opts, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $snow->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@capture, [$snow->snowsql, $snow->_quiet_opts, '--filename', 'foo/bar.sql'],
    'File should be passed to capture()';

ok $snow->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $snow->snowsql, $snow->_verbose_opts],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
# ok $snow->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
# is_deeply \@capture, [$snow->snowsql, '--filename', 'foo/bar.sql'],
#     'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $snow->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@capture, [$snow->snowsql, $snow->_verbose_opts, '--filename', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->(), 'foo'),
    q{to_varchar(CONVERT_TIMEZONE('UTC', foo), '"year:"YYYY":month:"MM":day:"DD":hour:"HH24":minute:"MI":second:"SS":time_zone:UTC"')},
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
        'DROP SCHEMA IF EXISTS sqitch CASCADE',
        'DROP SCHEMA IF EXISTS __sqitchtest CASCADE',
    );
}

$uri = URI->new($ENV{SNOWSQL_URI} || 'db:snowflake://accountname/?Driver=Snowflake');
my $err = try {
    $snow->use_driver;
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
        engine    => 'snowflake',
        top_dir   => Path::Class::dir(qw(t engine)),
        plan_file => Path::Class::file(qw(t engine sqitch.plan)),
    }],
    target_params     => [ uri => $uri ],
    alt_target_params => [ uri => $uri, registry => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have vsql and can connect to the database.
        $self->sqitch->probe( $self->client, '--version' );
        $self->_capture('--query' => 'SELECT CURRENT_DATE FROM dual');
    },
    engine_err_regex  => qr/\bSQL\s+compilation\s+error:/,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema()')->[0],
            '__SQITCHTEST', 'The Sqitch schema should be the current schema';
    },
    add_second_format => 'dateadd(second, 1, %s)',

);

done_testing;
