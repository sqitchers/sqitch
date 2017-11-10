#!/usr/bin/perl -w
#
# Made after sqlite.t and mysql.t
#
use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
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
my $have_fb_driver = 1; # assume DBD::Firebird is installed and so is Firebird
my $live_testing   = 0;

# Is DBD::Firebird realy installed?
try { require DBD::Firebird; } catch { $have_fb_driver = 0; };

BEGIN {
    $CLASS = 'App::Sqitch::Engine::firebird';
    require_ok $CLASS or die;
    $ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.user';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.sys';

    $user = $ENV{ISC_USER}     || $ENV{DBI_USER} || 'SYSDBA';
    $pass = $ENV{ISC_PASSWORD} || $ENV{DBI_PASS} || 'masterkey';

    $tmpdir = File::Spec->tmpdir();

    delete $ENV{ISC_PASSWORD};
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new(options => { engine => 'firebird' });
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:firebird:foo.fdb'),
);
isa_ok my $fb = $CLASS->new(sqitch  => $sqitch, target => $target), $CLASS;

is $fb->key, 'firebird', 'Key should be "firebird"';
is $fb->name, 'Firebird', 'Name should be "Firebird"';

my $have_fb_client;
if ($have_fb_driver && (my $client = try { $fb->client })) {
    $have_fb_client = 1;
    like $client, qr/isql|fbsql|isql-fb/,
        'client should default to isql | fbsql | isql-fb';
}

is $fb->uri->dbname, file('foo.fdb'), 'dbname should be filled in';
is $fb->registry_uri->dbname, 'sqitch.fdb',
    'registry dbname should be "sqitch.fdb"';

is $fb->registry_destination, $fb->registry_uri->as_string,
    'registry_destination should be the same as registry URI';

my @std_opts = (
    '-quiet',
    '-bail',
    '-sqldialect' => '3',
    '-pagelength' => '16384',
    '-charset'    => 'UTF8',
);

my $dbname = $fb->connection_string($fb->uri);
is_deeply([$fb->isql], [$fb->client, @std_opts, $dbname],
          'isql command should be std opts-only') if $have_fb_client;

isa_ok $fb = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
ok $fb->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';

is_deeply([$fb->isql], [$fb->client, @std_opts, $dbname],
          'isql command should be std opts-only') if $have_fb_client;

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.firebird.client'   => '/path/to/isql',
    'engine.firebird.target'   => 'db:firebird://freddy:s3cr3t@db.example.com:1234/widgets',
    'engine.firebird.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
$sqitch = App::Sqitch->new(options => { engine => 'firebird' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $fb = $CLASS->new(sqitch => $sqitch, target => $target), 'Create another firebird';

is $fb->client, '/path/to/isql', 'client should be as configured';
is $fb->uri, URI::db->new('db:firebird://freddy:s3cr3t@db.example.com:1234/widgets'),
    'URI should be as configured';
like $fb->destination, qr{db:firebird://freddy:?\@db.example.com:1234/widgets},
    'destination should default to URI without password';
like $fb->registry_destination, qr{db:firebird://freddy:?\@db.example.com:1234/meta},
    'registry_destination should be URI with configured registry and no password';
is_deeply [$fb->isql], [(
    '/path/to/isql',
    '-user', 'freddy',
    '-password', 's3cr3t',
), @std_opts, 'db.example.com/1234:widgets'], 'firebird command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(options => {
    engine   => 'firebird',
    client   => '/some/other/isql',
    registry => 'meta',
});
$target = App::Sqitch::Target->new(sqitch => $sqitch);

ok $fb = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a firebird with sqitch with options';

is $fb->client, '/some/other/isql', 'client should be as optioned';
is $fb->registry_uri,
    URI::db->new('db:firebird://freddy:s3cr3t@db.example.com:1234/meta'),
    'Registry URI should include --registry value.';
is_deeply [$fb->isql], [(
    '/some/other/isql',
    '-user', 'freddy',
    '-password', 's3cr3t',
), @std_opts, 'db.example.com/1234:widgets'], 'isql command should be as optioned';

##############################################################################
# Test connection_string.
can_ok $fb, 'connection_string';
for my $file (qw(
    foo.fdb
    /blah/hi.fdb
    C:/blah/hi.fdb
)) {
    # DB name only.
    is $fb->connection_string( URI::db->new("db:firebird:$file") ),
        $file, "Connection for db:firebird:$file";
    # DB name and host.
    is $fb->connection_string( URI::db->new("db:firebird:foo.com/$file") ),
        "foo.com/$file", "Connection for db:firebird:foo.com/$file";
    # DB name, host, and port
    is $fb->connection_string( URI::db->new("db:firebird:foo.com:1234/$file") ),
        "foo.com:1234/$file", "Connection for db:firebird:foo.com/$file:1234";
}

throws_ok { $fb->connection_string( URI::db->new('db:firebird:') ) }
    'App::Sqitch::X', 'Should get an exception for no db name';
is $@->ident, 'firebird', 'No dbname exception ident should be "firebird"';
is $@->message, __x(
    'Database name missing in URI {uri}',
    uri => 'db:firebird:',
), 'No dbname exception message should be correct';


##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $fb, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{ISC_PASSWORD}, $exp_pass, qq{ISC_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{ISC_PASSWORD}, 'ISC_PASSWORD should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{ISC_PASSWORD}, $exp_pass, qq{ISC_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{ISC_PASSWORD}, 'ISC_PASSWORD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{ISC_PASSWORD}, $exp_pass, qq{ISC_PASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{ISC_PASSWORD}, 'ISC_PASSWORD should not exist';
    }
});

$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $fb->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $fb->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $fb->isql],
    'Command should be passed to spool()';

ok $fb->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $fb = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a firebird with sqitch with no pw';
$exp_pass = undef;
$target->uri->password($exp_pass);
ok $fb->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $fb->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $fb->isql],
    'Command should be passed to spool() again';

ok $fb->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$fb->isql, qw(foo bar baz)],
    'Command should be passed to capture() again';

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

END {
    return unless $live_testing;
    return unless $have_fb_driver;

    foreach my $dbname (qw{__sqitchtest__ __sqitchtest __metasqitch}) {
        my $dbpath = catfile($tmpdir, $dbname);
        next unless -f $dbpath;
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

        $dbh->{Driver}->visit_child_handles(
            sub {
                my $h = shift;
                $h->disconnect
                    if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
            }
        );

        my $res = $dbh->selectall_arrayref(
            q{ SELECT MON$USER FROM MON$ATTACHMENTS }
        );
        if (@{$res} > 1) {
            # Do we have more than 1 active connections?
            diag "    Another active connection detected, can't DROP DATABASE!\n";
        }
        else {
            $dbh->func('ib_drop_database')
                or diag
                "Error dropping test database '$dbname': $DBI::errstr";
        }
    }
}

my $dbpath = catfile($tmpdir, '__sqitchtest__');
my $err = try {
    require DBD::Firebird;
    DBD::Firebird->create_database(
        {   db_path       => $dbpath,
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

my $uri = URI::db->new("db:firebird://$user:$pass\@localhost/$dbpath");
DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [options => {
        _engine     => 'firebird',
        top_dir     => Path::Class::dir(qw(t engine))->stringify,
        plan_file   => Path::Class::file(qw(t engine sqitch.plan))->stringify,
    }],
    target_params     => [ uri => $uri, registry => catfile($tmpdir, '__metasqitch') ],
    alt_target_params => [ uri => $uri, registry => catfile($tmpdir, '__sqitchtest') ],

    skip_unless => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have the right isql and can connect to the
        # database.  Adapted from the FirebirdMaker.pm module of
        # DBD::Firebird.
        my $cmd = $self->client;
        my $cmd_echo = qx(echo "quit;" | "$cmd" -z -quiet 2>&1 );
        return 0 unless $cmd_echo =~ m{Firebird}ims;
        # Skip if no DBD::Firebird.
        return 0 unless $have_fb_driver;
        $live_testing = 1;
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
