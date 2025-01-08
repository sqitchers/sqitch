#!/usr/bin/perl -w

# To test against a live Cockroach database, you must set the
# SQITCH_TEST_COCKROACH_URI environment variable. This is a standard URI::db
# URI, and should look something like this:
#
#     export SQITCH_TEST_COCKROACH_URI=db:cockroach://root:password@localhost:26257/sqitchtest
#

use strict;
use warnings;
use 5.010;
use Test::More 0.94;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use Try::Tiny;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use Path::Class;
use DBD::Mem;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::cockroach';
    require_ok $CLASS or die;
    delete $ENV{PGPASSWORD};
}

my $uri = URI::db->new('db:cockroach:');
my $config = TestConfig->new('core.engine' => 'cockroach');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $cockroach = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $cockroach->key, 'cockroach', 'Key should be "cockroach"';
is $cockroach->name, 'CockroachDB', 'Name should be "CockroachDB"';
is $cockroach->driver, 'DBD::Pg 2.0', 'Driver should be "DBD::Pg 2.0"';
is $cockroach->wait_lock, 1, 'wait_lock should return 1';

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char_format'), "$CLASS->can('_ts2char_format')";
is sprintf($ts2char->($cockroach), 'foo'),
    q{experimental_strftime(foo AT TIME ZONE 'UTC', 'year:%Y:month:%m:day:%d:hour:%H:minute:%M:second:%S:time_zone:UTC')},
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
# Test table error methods.
DBI: {
    local *DBI::state;
    ok !$cockroach->_no_table_error, 'Should have no table error';
    ok !$cockroach->_no_column_error, 'Should have no column error';

    $DBI::state = '42703';
    ok !$cockroach->_no_table_error, 'Should again have no table error';
    ok $cockroach->_no_column_error, 'Should now have no column error';

    $DBI::state = '42P01';
    ok $cockroach->_no_table_error, 'Should now have table error';
    ok !$cockroach->_no_column_error, 'Still should have no column error';
}

##############################################################################
# Test _run_registry_file.
RUNREG: {
    # Mock I/O used by _run_registry_file.
    my $mock_engine = Test::MockModule->new($CLASS);
    my @ran;
    $mock_engine->mock(_run => sub { shift; push @ran, \@_ });

    # Mock up the database handle.
    my $dbh = DBI->connect('dbi:Mem:', undef, undef, {});
    $mock_engine->mock(dbh => $dbh );
    my $mock_dbd = Test::MockModule->new(ref $dbh, no_auto => 1);
    my @done;
    $mock_dbd->mock(do => sub { shift; push @done, \@_; 1 });

    # Find the SQL file.
    my $ddl = file($INC{'App/Sqitch/Engine/cockroach.pm'})->dir->file('cockroach.sql');

    # Test it!
    my $registry = $cockroach->registry;
    ok $cockroach->_run_registry_file($ddl), 'Run the registry file';
    is_deeply \@ran, [[
        '--file' => $ddl,
        '--set'  => "registry=$registry",
    ]], 'Shoud have deployed the original SQL file';
    is_deeply \@done, [['SET search_path = ?', undef, $registry]],
        'The registry should have been added to the search path';
}

##############################################################################
# Can we do live tests?
$config->replace('core.engine' => 'cockroach');
$sqitch = App::Sqitch->new(config => $config);
$target = App::Sqitch::Target->new( sqitch => $sqitch );
$cockroach = $CLASS->new(sqitch => $sqitch, target => $target);

$uri = URI->new(
    $ENV{SQITCH_TEST_COCKROACH_URI}
    || 'db:cockroach://' . ($ENV{PGUSER} || 'root') . "\@localhost/"
);

my $dbh;
my $id = DBIEngineTest->randstr;
my ($db, $reg1, $reg2) = map { $_ . $id } qw(__sqitchtest__ sqitch __sqitchtest);

END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    # Drop the database or schema.
    $dbh->do("DROP DATABASE $db") if $dbh->{Active}
}

my $err = try {
    $cockroach->_capture('--version');
    $cockroach->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError  => 0,
        RaiseError  => 0,
        AutoCommit  => 1,
        HandleError => $cockroach->error_handler,
        cockroach_lc_messages => 'C',
    });
    $dbh->do("CREATE DATABASE $db");
    $uri->dbname($db);
    undef;
} catch {
    $_
};

DBIEngineTest->run(
    class             => $CLASS,
    version_query     => 'SELECT version()',
    target_params     => [ uri => $uri, registry => $reg1 ],
    alt_target_params => [ uri => $uri, registry => $reg2 ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have psql and can connect to the database.
        my $version = $self->sqitch->capture( $self->client, '--version' );
        say "# Detected $version";
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/^ERROR:  /,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $reg2,
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            $reg2, 'The Sqitch schema should be the current schema';
    },
);

done_testing;
