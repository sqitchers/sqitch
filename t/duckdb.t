use 5.010;
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Exception;
use Test::MockModule;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::X qw(hurl);
use Path::Class;
use Try::Tiny;
use Locale::TextDomain qw(App-Sqitch);
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::duckdb';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return the correct values';

# Use a temp directory for the test database.
my $tmp_dir = tempdir(CLEANUP => 1);

# Mock the sqitch to use our config.
my $config = TestConfig->new('core.engine' => 'duckdb');

my $sqitch = App::Sqitch->new(config => $config);
my $db_name = file($tmp_dir, 'sqitch_test.db');

ok my $duckdb = $CLASS->new(
    sqitch => $sqitch,
    target => App::Sqitch::Target->new(
        sqitch => $sqitch,
        uri    => URI->new("db:duckdb:$db_name"),
    ),
), 'Create a DuckDB engine';

isa_ok $duckdb, 'App::Sqitch::Engine::duckdb';
isa_ok $duckdb, 'App::Sqitch::Engine';
is $duckdb->key, 'duckdb', 'The key should be "duckdb"';
is $duckdb->name, 'DuckDB', 'The name should be "DuckDB"';
is $duckdb->driver, 'DBD::DuckDB 0.16', 'The driver should be correct';

# Test error handling for missing db name.
my $bad_target = App::Sqitch::Target->new(sqitch => $sqitch);
my $bad_engine = $CLASS->new( sqitch => $sqitch, target => $bad_target );
throws_ok {
    $bad_engine->duckdb
} 'App::Sqitch::X', 'Should die without a database name';

# Test _regex_op.
is $CLASS->_regex_op, 'REGEXP_MATCHES', '_regex_op should be REGEXP_MATCHES';
is_deeply [$CLASS->_regex_expr('col', '.*foo.*')],
    ['REGEXP_MATCHES(col, ?)', '.*foo.*'],
    '_regex_expr should produce function-call syntax';

# Test error detection methods.
ERRSTR: {
    local *DBI::errstr;
    ok !$duckdb->_no_table_error, 'Should have no table error';
    ok !$duckdb->_no_column_error, 'Should have no column error';
    ok !$duckdb->_unique_error, 'Should have no unique error';

    $DBI::errstr = 'Catalog Error: Table with name changes does not exist';
    ok $duckdb->_no_table_error, 'Should detect table error';
    ok !$duckdb->_no_column_error, 'Should not detect column error';
    ok !$duckdb->_unique_error, 'Should not detect unique error';

    $DBI::errstr = 'Binder Error: No column named foo';
    ok !$duckdb->_no_table_error, 'Should not detect table error';
    ok $duckdb->_no_column_error, 'Should detect column error';
    ok !$duckdb->_unique_error, 'Should not detect unique error';

    $DBI::errstr = 'Constraint Error: Duplicate key';
    ok !$duckdb->_no_table_error, 'Should not detect table error';
    ok !$duckdb->_no_column_error, 'Should not detect column error';
    ok $duckdb->_unique_error, 'Should detect unique error';
}

# Test DateTime formatting.
ok my $ts2char = $CLASS->can('_ts2char_format'), '_ts2char_format should be available';
is sprintf($ts2char->($duckdb), 'foo'),
    q{strftime('year:%Y:month:%m:day:%d:hour:%H:minute:%M:second:%S:time_zone:UTC', foo)},
    '_ts2char_format should work';

ok my $dtfunc = $CLASS->can('_dt'), '_dt should be available';
isa_ok my $dt = $dtfunc->(
    'year:2012:month:07:day:05:hour:15:minute:07:second:01:time_zone:UTC'
), 'App::Sqitch::DateTime', 'Return value of _dt()';
is $dt->year,  2012, 'DateTime year should be set';
is $dt->month,    7, 'DateTime month should be set';
is $dt->day,      5, 'DateTime day should be set';
is $dt->hour,    15, 'DateTime hour should be set';
is $dt->minute,   7, 'DateTime minute should be set';
is $dt->second,   1, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be set';

# Test template availability.
DBIEngineTest->test_templates_for($duckdb->key);

# Test DBIEngine integration.
my $id = DBIEngineTest::randstr;
my ($reg1, $reg2) = map { $_ . $id } qw(sqitch sqitchtest);

DBIEngineTest->run(
    class             => $CLASS,
    target_params     => [
        uri => URI->new("db:duckdb:$db_name"),
        registry => $reg1,
    ],
    alt_target_params => [
        uri => URI->new("db:duckdb:$db_name"),
        registry => $reg2,
    ],
    init_error    => __x(
        'Sqitch database {database} already initialized',
        database => "$db_name",
    ),
    engine_err_regex => qr{^Catalog Error}x,
    skip_unless       => sub {
        my $self = shift;
        eval { require DBD::DuckDB; 1 } or return;
        diag 'Testing with DuckDB' if $ENV{TEST_VERBOSE};
    },
    version_query     => q{SELECT 'DuckDB ' || version()},
);

done_testing;
