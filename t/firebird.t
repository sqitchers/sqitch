#!/usr/bin/perl -w
#
# Made after mysql.t
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
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::firebird';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
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
isa_ok my $fb = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'isql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $fb->client, $client, 'client should default to isql';
is $fb->sqitch_db, 'sqitch', 'sqitch_db default should be "sqitch"';
for my $attr (qw(username password db_name host port destination)) {
    is $fb->$attr, undef, "$attr default should be undef";
}

is $fb->meta_destination, $fb->sqitch_db,
    'meta_destination should be the same as sqitch_db';

my @std_opts = (
    '-bail',
    '-quiet',
    '-sqldialect 3',
    '-pagelength 16384',
);
is_deeply [$fb->isql], [$client, @std_opts],
    'isql command should be std opts-only';

isa_ok $fb = $CLASS->new(sqitch => $sqitch, db_name => 'foo'), $CLASS;
ok $fb->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$fb->isql], [
    $client,
    # '--foo' => 'baz',
    # '--whu' => 'hi there',
    # '--yo'  => 'stellar',
    '-database' => 'foo',
    @std_opts,
], 'Variables should not be passed to firebird';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.firebird.client'    => '/path/to/isql',
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

is $fb->client, '/path/to/isql', 'client should be as configured';
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
    -quiet
    -bail
    -sqldialect 3
    -pagelength 16384
    -charset UTF8
), @std_opts], 'firebird command should be configured';

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

is $fb->client, '/some/other/isql', 'client should be as optioned';
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
    -sqldialect 3
    -pagelength 16384
    -charset UTF8
    -bail
    -quiet
), @std_opts], 'isql command should be as optioned';

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
is_deeply \@run, [$fb->isql, '-input', 'source foo/bar.sql'],
    'File should be passed to run()';

ok $fb->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $fb->isql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $fb->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$fb->isql, '-input', 'source foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $fb->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$fb->isql, '-input', 'source foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

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
        || ':second:' || CAST(EXTRACT(SECOND FROM foo) AS INTEGER)
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
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        use Data::Printer; p $h;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    return unless $dbh->{Active};
    $dbh->func('ib_drop_database')
        or return 'Error dropping test database';
    # $dbh->do("DROP DATABASE IF EXISTS $_") for qw(
    #     __sqitchtest__
    #     __metasqitch
    #     __sqitchtest
    # );
}

my $pass = $ENV{DBI_PASS} || '';

my $err = try {
    my $path = '/home/fbdb/__sqitchtest__';
    print "=t= CREATE DATABASE", $path, "\n";
    require DBD::Firebird;
    DBD::Firebird->create_database(
        {   db_path       => $path,
            user          => 'SYSDBA',
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
        db_name     => '__sqitchtest__',
        top_dir     => Path::Class::dir(qw(t engine)),
        plan_file   => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ password => $pass, sqitch_db => '/home/fbdb/__metasqitch' ],
    alt_engine_params => [ password => $pass, sqitch_db => '/home/fbdb/__sqitchtest' ],

    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have isql and can connect to the database.
        #$self->sqitch->probe( $self->client, '-d', '__sqitchtest' );
        # $self->_capture('--execute' => 'SELECT version()');
        1;
    },
    engine_err_regex  => qr/^Invalid token /,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => '__sqitchtest',
    ),
    add_second_format => q{dateadd(1 second to %s)},
    test_dbh => sub {
        my $dbh = shift;
        # Check the session configuration.
        # for my $spec (
        #     [ib_enable_utf8   => 1],
        # ) {
        #     is $dbh->selectcol_arrayref('SELECT @@SESSION.' . $spec->[0])->[0],
        #         $spec->[1], "Setting $spec->[0] should be set to $spec->[1]";
        # }
    },
);

done_testing;
