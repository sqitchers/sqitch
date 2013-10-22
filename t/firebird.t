#!/usr/bin/perl -w
#
# Made after sqlite.t and mysql.t
#
use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Test::MockModule;
use Path::Class;
use Try::Tiny;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use File::Spec::Functions;
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;

my $CLASS;
my $user;
my $pass;
my $tmpdir;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::firebird';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';

    $user = $ENV{DBI_USER} || 'SYSDBA';
    $pass = $ENV{DBI_PASS} || '';

    $tmpdir = File::Spec->tmpdir();
}

is_deeply [$CLASS->config_vars], [
    client    => 'any',
    username  => 'any',
    password  => 'any',
    db_name   => 'any',
    host      => 'any',
    port      => 'int',
    sqitch_db => 'any',
], 'config_vars should return seven vars';

my $sqitch = App::Sqitch->new;
isa_ok my $fb = $CLASS->new(sqitch => $sqitch, db_name => 'foo.fdb'), $CLASS;

like ( $fb->client, qr/isql/, 'client should default to isql');
is $fb->db_name, file('foo.fdb'), 'db_name should be required';
is $fb->sqitch_db, './sqitch.fdb', 'sqitch_db default should be "sqitch.fdb"';
for my $attr (qw(username password host port)) {
    is $fb->$attr, undef, "$attr default should be undef";
}

is $fb->meta_destination, $fb->sqitch_db,
    'meta_destination should be the same as sqitch_db';

my @std_opts = (
    '-quiet',
    '-bail',
    '-sqldialect' => '3',
    '-pagelength' => '16384',
    '-charset'    => 'UTF8',
);
is_deeply [$fb->isql], [$fb->client, @std_opts, $fb->db_name],
    'isql command should be std opts-only';

isa_ok $fb = $CLASS->new(sqitch => $sqitch, db_name => 'foo'), $CLASS;
ok $fb->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$fb->isql], [
    $fb->client,
    @std_opts,
    $fb->db_name
], 'Variables should not be passed to firebird';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.firebird.client'    => file(qw{/ path to isql}),
    'core.firebird.username'  => 'freddy',
    'core.firebird.password'  => 's3cr3t',
    'core.firebird.db_name'   => 'widgets',
    'core.firebird.host'      => 'db.example.com',
    'core.firebird.port'      => 1234,
    'core.firebird.sqitch_db' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $fb = $CLASS->new(sqitch => $sqitch), 'Create another firebird';

is $fb->client, file(qw{/ path to isql}), 'client should be as configured';
is $fb->username, 'freddy', 'username should be as configured';
is $fb->password, 's3cr3t', 'password should be as configured';
is $fb->db_name, 'widgets', 'db_name should be as configured';
is $fb->destination, 'widgets', 'destination should default to db_name';
is $fb->meta_destination, 'meta', 'meta_destination should be as configured';
is $fb->host, 'db.example.com', 'host should be as configured';
is $fb->port, 1234, 'port should be as configured';
is $fb->sqitch_db, 'meta', 'sqitch_db should be as configured';
is_deeply [$fb->isql], [qw(
    /path/to/isql
    -host db.example.com
    -port 1234
    -user freddy
    -password s3cr3t
), @std_opts, $fb->db_name], 'firebird command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    db_client   => '/some/other/isql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $fb = $CLASS->new(sqitch => $sqitch),
    'Create a firebird with sqitch with options';

is $fb->client, file(qw{/ some other isql}), 'client should be as optioned';
is $fb->username, 'anna', 'username should be as optioned';
is $fb->password, 's3cr3t', 'password should still be as configured';
is $fb->db_name, 'widgets_dev', 'db_name should be as optioned';
is $fb->destination, 'widgets_dev', 'destination should still default to db_name';
is $fb->meta_destination, 'meta', 'meta_destination should still be configured';
is $fb->host, 'foo.com', 'host should be as optioned';
is $fb->port, 98760, 'port should be as optioned';
is $fb->sqitch_db, 'meta', 'sqitch_db should still be as configured';
is_deeply [$fb->isql], [qw(
    /some/other/isql
    -host     foo.com
    -port     98760
    -user     anna
    -password s3cr3t
), @std_opts, $fb->db_name], 'isql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $fb, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my @run;
$mock_sqitch->mock(run => sub { shift; @run = @_; });

my @capture;
$mock_sqitch->mock(capture => sub { shift; @capture = @_; });

my @spool;
$mock_sqitch->mock(spool => sub { shift; @spool = @_; });

ok $fb->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $fb->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $fb->isql],
    'Command should be passed to spool()';

ok $fb->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to capture()';

##############################################################################
# Test file and handle running.
ok $fb->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$fb->isql, '-input', 'foo/bar.sql'],
    'File should be passed to run()';

ok $fb->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $fb->isql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $fb->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$fb->isql, '-input', 'foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $fb->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$fb->isql, '-input', 'foo/bar.sql'],
    'Verify file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char_format';
is sprintf($CLASS->_ts2char_format, 'foo'),
    q{'year:' || CAST(EXTRACT(YEAR   FROM foo) AS SMALLINT)
        || ':month:'  || CAST(EXTRACT(MONTH  FROM foo) AS SMALLINT)
        || ':day:'    || CAST(EXTRACT(DAY    FROM foo) AS SMALLINT)
        || ':hour:'   || CAST(EXTRACT(HOUR   FROM foo) AS SMALLINT)
        || ':minute:' || CAST(EXTRACT(MINUTE FROM foo) AS SMALLINT)
        || ':second:' || FLOOR(CAST(EXTRACT(SECOND FROM foo) AS NUMERIC(9,4)))
        || ':time_zone:UTC'},
    '_ts2char_format should work';           # WORKS! :)
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
    foreach my $dbname (qw{__sqitchtest__ __sqitchtest __metasqitch}) {
        my $dbpath = catfile($tmpdir, $dbname);
        print "=t= DROP DATABASE $dbpath\n";
        my $dsn = qq{dbi:Firebird:dbname=$dbpath;host=localhost;port=3050};
        $dsn .= q{;ib_dialect=3;ib_charset=UTF8};

        my $dbh = DBI->connect(
            $dsn, $user, $pass,
            {   FetchHashKeyName => 'NAME_lc',
                AutoCommit       => 1,
                RaiseError       => 0,
                PrintError       => 0,
            }
        ) or die $DBI::errstr;

        # -lock time-out on wait transaction
        # -object /tmp/__sqitchtest is in use at t/firebird.t line 234.
        $dbh->func('ib_drop_database')
            or warn "Error dropping test database '$dbname': $DBI::errstr";
    }
}

my $err = try {
    my $path = catfile($tmpdir, '__sqitchtest__');
    print "=t= CREATE DATABASE ", $path, "\n";
    require DBD::Firebird;
    DBD::Firebird->create_database(
        {   db_path       => $path,
            user          => $user,
            password      => $pass,
            character_set => 'UTF8',
            page_size     => 16384,
        }
    );
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        db_username => 'SYSDBA',
        db_name     => catfile($tmpdir, '__sqitchtest__'),
        top_dir     => Path::Class::dir(qw(t engine)),
        plan_file   => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ password => $pass, sqitch_db => catfile($tmpdir, '__metasqitch') ],
    alt_engine_params => [ password => $pass, sqitch_db => catfile($tmpdir, '__sqitchtest') ],

    skip_unless => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have the right isql and can connect to the
        # database.  Adapted from the FirebirdMaker.pm module of
        # DBD::Firebird.
        my $cmd = $self->client;
        my $cmd_echo = qx( echo "quit;" | "$cmd" -z -quiet 2>&1 );
        return 0 unless $cmd_echo =~ m{Firebird}ims;
    },
    engine_err_regex  => qr/\QDynamic SQL Error\E/xms,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => catfile($tmpdir, '__sqitchtest'),
    ),
    add_second_format => q{dateadd(1 second to %s)},
    test_dbh => sub {
        my $dbh = shift;
        # Check the session configuration...
        # To try: http://www.firebirdsql.org/refdocs/langrefupd21-intfunc-get_context.html
    },
);

done_testing;
