#!/usr/bin/perl -w

# To test against a live Snowflake database, you must set the SNOWSQL_URI environment variable.
# this is a stanard URI::db URI, and should look something like this:
#
#     export SNOWSQL_URI=db:snowflake://username:password@accountname/dbname?Driver=Snowflake;warehouse=warehouse
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
use File::Temp 'tempdir';
use Path::Class;
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use App::Sqitch::DateTime;
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

# Mock the home directory to prevent reading a user config file.
require File::HomeDir;
my $tmp_dir = dir tempdir CLEANUP => 1;
my $mock_home = Test::MockModule->new('File::HomeDir');
$mock_home->mock(my_home => $tmp_dir->stringify);

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = 'db:snowflake:';
my $sqitch = App::Sqitch->new(options => { engine => 'snowflake' });
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI::db->new($uri),
);

# Disable config file parsing for the remainder of the tests.
my $mock_snow = Test::MockModule->new($CLASS);
$mock_snow->mock(_snowcfg => {});

isa_ok my $snow = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

is $snow->username, $sqitch->sysuser, 'Username should be sysuser';
is $snow->password, undef, 'Password should be undef';
is $snow->key, 'snowflake', 'Key should be "snowflake"';
is $snow->name, 'Snowflake', 'Name should be "Snowflake"';
is $snow->driver, 'DBD::ODBC 1.59', 'Driver should be DBD::ODBC';
is $snow->default_client, 'snowsql', 'Default client should be snowsql';
my $client = 'snowsql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $snow->client, $client, 'client should default to snowsql';

is $snow->registry, 'sqitch', 'Registry default should be "sqitch"';
my $exp_uri = sprintf 'db:snowflake://%s.snowflakecomputing.com/%s',
    $ENV{SNOWSQL_ACCOUNT}, $sqitch->sysuser;
is $snow->uri, $exp_uri, 'DB URI should be filled in';
is $snow->destination, $exp_uri, 'Destination should be URI string';
is $snow->registry_destination, $snow->destination,
    'Registry destination should be the same as destination';

# Test environment variables.
SNOWENV: {
    local $ENV{SNOWSQL_USER} = 'kamala';
    local $ENV{SNOWSQL_PWD} = 'gimme';
    local $ENV{SNOWSQL_REGION} = 'Australia';
    local $ENV{SNOWSQL_WAREHOUSE} = 'madrigal';
    local $ENV{SNOWSQL_ACCOUNT} = 'egregious';
    local $ENV{SNOWSQL_HOST} = 'test.snowflake.com';
    local $ENV{SNOWSQL_PORT} = 4242;
    local $ENV{SNOWSQL_DATABASE} = 'tryme';

    my $target = App::Sqitch::Target->new(sqitch => $sqitch, uri => URI->new($uri));
    my $snow = $CLASS->new( sqitch => $sqitch, target => $target );
    is $snow->uri, 'db:snowflake://test.snowflake.com:4242/tryme',
        'Should build URI from environment';
    is $snow->username, 'kamala', 'Should read username from environment';
    is $snow->password, 'gimme', 'Should read password from environment';
    is $snow->account, 'test', 'Should read account from host';
    is $snow->warehouse, 'madrigal', 'Should read warehouse from environment';

    # Delete host.
    $target = App::Sqitch::Target->new(sqitch => $sqitch, uri => URI->new($uri));
    delete $ENV{SNOWSQL_HOST};
    $snow = $CLASS->new( sqitch => $sqitch, target => $target );
    is $snow->uri, 'db:snowflake://egregious.Australia.snowflakecomputing.com:4242/tryme',
        'Should build URI host from account and region environment vars';
    is $snow->account, 'egregious', 'Should read account from environment';

    # SQITCH_PASSWORD has priority.
    local $ENV{SQITCH_PASSWORD} = 'irule';
    $target = App::Sqitch::Target->new(sqitch => $sqitch, uri => URI->new($uri));
    is $target->password, 'irule', 'Target password should be from SQITCH_PASSWORD';
    $snow = $CLASS->new( sqitch => $sqitch, target => $target );
    is $snow->password, 'irule', 'Should prefer password from SQITCH_PASSWORD';
}

# Name the target.
my $named_target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new($uri),
    name   => 'jonsnow',
);

isa_ok $snow = $CLASS->new(
    sqitch => $sqitch,
    target => $named_target,
), $CLASS;

is $snow->destination, 'jonsnow', 'Destination should be target name';
is $snow->registry_destination, $snow->destination,
    'Registry destination should be the same as destination';

##############################################################################
# Test snowsql options.
my @con_opts = (
    '--accountname' => $ENV{SNOWSQL_ACCOUNT},
    '--username' => $snow->username,
    '--dbname' => $snow->uri->dbname,
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
            'Registry target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $snow = $CLASS->new(sqitch => $sqitch, target => $target);
    is $snow->target->name, 'db:snowflake:',
        'Target name should not fall back on sysuser';
    is $snow->registry_destination, $snow->destination,
        'Registry target should be the same as destination';

    $ENV{SNOWSQL_DATABASE} = 'mydb';
    $snow = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $snow->target->name, 'db:snowflake:',  'Target name should be the default';
    is $snow->registry_destination, $snow->destination,
        'Registry target should be the same as destination';
}

##############################################################################
# Make sure we read snowsql config file.
SNOWSQLCFGFILE: {
    # Create the mock config directory.
    my $cfgdir = $tmp_dir->subdir('.snowsql');
    $cfgdir->mkpath;
    my $cfgfn = $cfgdir->file('config');

    my $cfg = {
        username      => 'jonSnow',
        password      => 'winter is cøming',
        accountname   => 'golem',
        region        => 'Africa',
        warehousename => 'LaBries',
        dbname        => 'dolphin',
    };

    # Unset the mock.
    $mock_snow->unmock('_snowcfg');

    for my $qm (q{}, q{'}, q{"}) {
        # Write out a the config file.
        open my $fh, '>:utf8', $cfgfn or die "Cannot open $cfgfn: $!\n";
        print {$fh} "[connections]\n";
        while (my ($k, $v) = each %{ $cfg }) {
            print {$fh} "$k = $qm$v$qm\n";
        }

        # Add a named connection, which should be ignored.
        print {$fh} "[connections.winner]\nusername = ${qm}WINNING$qm\n";
        close $fh or die "Cannot close $cfgfn: $!\n";

        # Make sure we read it in.
        my $target = App::Sqitch::Target->new(
            name => 'db:snowflake:',
            sqitch => $sqitch,
        );
        my $snow = $CLASS->new( sqitch => $sqitch, target => $target );
        is_deeply $snow->_snowcfg, $cfg, 'Should have read config from file';
    }

    # Reset default mock.
    $mock_snow->mock(_snowcfg => {});
}

##############################################################################
# Make sure we read snowsql config connection settings.
SNOWSQLCFG: {
    local $ENV{SNOWSQL_ACCOUNT};
    local $ENV{SNOWSQL_HOST};
    my $target = App::Sqitch::Target->new(
        name => 'db:snowflake:',
        sqitch => $sqitch,
    );

    # Read config.
    $mock_snow->mock(_snowcfg => {
        username      => 'jon_snow',
        password      => 'let me in',
        accountname   => 'flipr',
        warehousename => 'Waterbed',
        dbname        => 'monkey',
    });
    my $snow = $CLASS->new( sqitch => $sqitch, target => $target );
    is $snow->username, 'jon_snow',
        'Should read username fron snowsql config file';
    is $snow->password, 'let me in',
        'Should read password fron snowsql config file';
    is $snow->account, 'flipr',
        'Should read accountname fron snowsql config file';
    is $snow->uri->dbname, 'monkey',
        'Should read dbname from snowsql config file';
    is $snow->warehouse, 'Waterbed',
        'Should read warehousename fron snowsql config file';
    is $snow->uri->host, 'flipr.snowflakecomputing.com',
        'Should derive host name from config file accounte name';

    # Reset default mock.
    $mock_snow->mock(_snowcfg => {});
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.snowflake.client'   => '/path/to/snowsql',
    'engine.snowflake.target'   => 'db:snowflake://fred:hi@foo/try?warehouse=foo',
    'engine.snowflake.registry' => 'meta',
);
$std_opts[-3] = 'registry=meta';
$std_opts[-1] = 'warehouse=foo';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $snow = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another snowflake';

is $snow->account, 'foo', 'Should extract account from URI';
is $snow->username, 'fred', 'Should extract username from URI';
is $snow->password, 'hi', 'Should extract password from URI';
is $snow->warehouse, 'foo', 'Should extract warehouse from URI';
is $snow->registry, 'meta', 'registry should be as configured';
is $snow->uri->as_string,
    'db:snowflake://fred:hi@foo.snowflakecomputing.com/try?warehouse=foo',
    'URI should be as configured with full domain name';
is $snow->destination,
    'db:snowflake://fred:@foo.snowflakecomputing.com/try?warehouse=foo',
    'Destination should omit password';

is $snow->client, '/path/to/snowsql', 'client should be as configured';
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

$mock_config->unmock('get');

##############################################################################
# Test SQL helpers.
is $snow->_listagg_format, q{listagg(%s, ' ')}, 'Should have _listagg_format';
is $snow->_ts_default, 'current_timestamp', 'Should have _ts_default';
is $snow->_regex_op, 'REGEXP', 'Should have _regex_op';
is $snow->_simple_from, ' FROM dual', 'Should have _simple_from';
is $snow->_limit_default, '4611686018427387903', 'Should have _limit_default';

DBI: {
    local *DBI::state;
    ok !$snow->_no_table_error, 'Should have no table error';
    ok !$snow->_no_column_error, 'Should have no column error';
    $DBI::state = '02000';
    ok $snow->_no_table_error, 'Should now have table error';
    ok !$snow->_no_column_error, 'Still should have no column error';
    $DBI::state = '42703';
    ok !$snow->_no_table_error, 'Should again have no table error';
    ok $snow->_no_column_error, 'Should now have no column error';
}

is_deeply [$snow->_limit_offset(8, 4)],
    [['LIMIT 8', 'OFFSET 4'], []],
    'Should get limit and offset';
is_deeply [$snow->_limit_offset(0, 2)],
    [['LIMIT 4611686018427387903', 'OFFSET 2'], []],
    'Should get limit and offset when offset only';
is_deeply [$snow->_limit_offset(12, 0)], [['LIMIT 12'], []],
    'Should get only limit with 0 offset';
is_deeply [$snow->_limit_offset(12)], [['LIMIT 12'], []],
    'Should get only limit with noa offset';
is_deeply [$snow->_limit_offset(0, 0)], [[], []],
    'Should get no limit or offset for 0s';
is_deeply [$snow->_limit_offset()], [[], []],
    'Should get no limit or offset for no args';

is_deeply [$snow->_regex_expr('corn', 'Obama$')],
    ["regexp_substr(corn, ?) IS NOT NULL", 'Obama$'],
    'Should use regexp_substr IS NOT NULL for regex expr';

##############################################################################
# Test _run(), _capture() _spool(), and _probe().
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

my @probe;
$mock_sqitch->mock(probe => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @probe = @_;
    if (defined $exp_pass) {
        is $ENV{SNOWSQL_PWD}, $exp_pass, qq{SNOWSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{SNOWSQL_PWD}, 'SNOWSQL_PWD should not exist';
    }
    return;
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

lives_ok { $snow->_probe(qw(foo bar baz)) } 'Call _probe';
is_deeply \@probe, [$snow->snowsql, $snow->_verbose_opts, qw(foo bar baz)],
    'Command should be passed to probe()';

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

lives_ok { $snow->_probe(qw(foo bar baz)) } 'Call _probe again';
is_deeply \@probe, [$snow->snowsql, $snow->_verbose_opts, qw(foo bar baz)],
    'Command should be passed to probe() again';

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

ok my $now = App::Sqitch::DateTime->now, 'Construct a datetime object';
is $snow->_char2ts($now), $now->as_string(format => 'iso'),
    'Should get ISO output from _char2ts';

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
$uri->host($uri->host . ".snowflakecomputing.com") if $uri->host !~ /snoflakecomputing[.]com/;
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
        top_dir   => dir(qw(t engine)),
        plan_file => file(qw(t engine sqitch.plan)),
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
