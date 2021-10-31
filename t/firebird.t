#!/usr/bin/perl -w
#
# To test against a live Firebird database, you must set the FIREBIRD_URI environment variable.
# this is a stanard URI::db URI, and should look something like this:
#
#     export FIREBIRD_URI=db:firebird://sysdba:password@localhost//path/to/test.db
#
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
use File::Basename qw(dirname);
use File::Spec::Functions;
use File::Temp 'tempdir';
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;
my $uri;
my $tmpdir;
my $have_fb_driver = 1; # assume DBD::Firebird is installed and so is Firebird

# Is DBD::Firebird realy installed?
try { require DBD::Firebird; } catch { $have_fb_driver = 0; };

BEGIN {
    $CLASS = 'App::Sqitch::Engine::firebird';
    require_ok $CLASS or die;
    $uri = URI->new($ENV{FIREBIRD_URI} || do {
        my $user = $ENV{ISC_USER}     || $ENV{DBI_USER} || 'SYSDBA';
        my $pass = $ENV{ISC_PASSWORD} || $ENV{DBI_PASS} || 'masterkey';
        "db:firebird://$user:$pass@/"
    });
    delete $ENV{$_} for qw(ISC_USER ISC_PASSWORD);
    $tmpdir = File::Spec->tmpdir();
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $config = TestConfig->new('core.engine' => 'firebird');
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:firebird:foo.fdb'),
);
isa_ok my $fb = $CLASS->new(sqitch  => $sqitch, target => $target), $CLASS;

is $fb->key, 'firebird', 'Key should be "firebird"';
is $fb->name, 'Firebird', 'Name should be "Firebird"';
is $fb->username, $ENV{ISC_USER}, 'Should have username from environment';
is $fb->password, $ENV{ISC_PASSWORD}, 'Should have password from environment';

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
# Make sure environment variables are read.
ENV: {
    local $ENV{ISC_USER} = '__kamala__';
    local $ENV{ISC_PASSWORD} = 'answer the question';
    ok my $fb = $CLASS->new(sqitch => $sqitch, target => $target),
        'Create a firebird with environment variables set';
    is $fb->username, $ENV{ISC_USER}, 'Should have username from environment';
    is $fb->password, $ENV{ISC_PASSWORD}, 'Should have password from environment';
}

##############################################################################
# Make sure config settings override defaults.
$config->update(
    'engine.firebird.client'   => '/path/to/isql',
    'engine.firebird.target'   => 'db:firebird://freddy:s3cr3t@db.example.com:1234/widgets',
    'engine.firebird.registry' => 'meta',
);
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
my ($data_dir, $fb_version, @cleanup) = ($tmpdir);
my $err = try {
    return unless $have_fb_driver;
    if ($uri->dbname) {
        $data_dir = dirname $uri->dbname; # Assumes local OS semantics.
    } else {
        # Assume we're running locally and create the database.
        my $dbpath = catfile($tmpdir, '__sqitchtest__');
        $data_dir = $tmpdir;
        $uri->dbname($dbpath);
        DBD::Firebird->create_database({
            db_path       => $dbpath,
            user          => $uri->user,
            password      => $uri->password,
            character_set => 'UTF8',
            page_size     => 16384,
        });
        @cleanup = ($dbpath);
    }
    # Try to connect.
    my $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });
    $fb_version = $dbh->selectcol_arrayref(q{
        SELECT rdb$get_context('SYSTEM', 'ENGINE_VERSION')
          FROM rdb$database
      })->[0];
    push @cleanup => map { catfile $data_dir, $_ } qw(__sqitchtest __metasqitch);
    return undef;
} catch {
    eval { $_->message } || $_;
};

END {
    return if $ENV{CI}; # No need to clean up under Travis.
    foreach my $dbname (@cleanup) {
        $uri->dbname($dbname);
        my $dsn = $uri->dbi_dsn . q{;ib_dialect=3;ib_charset=UTF8};
        my $dbh = DBI->connect($dsn, $uri->user, $uri->password, {
            FetchHashKeyName => 'NAME_lc',
            AutoCommit       => 1,
            RaiseError       => 0,
            PrintError       => 0,
        }) or die $DBI::errstr;

        # Disconnect any other database handles.
        $dbh->{Driver}->visit_child_handles(sub {
            my $h = shift;
            $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
        });

        # Kill all other connections.
        $dbh->do('DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID <> CURRENT_CONNECTION');
        $dbh->func('ib_drop_database') or diag "Cannot drop '$dbname': $DBI::errstr";
    }
}

DBIEngineTest->run(
    class             => $CLASS,
    target_params     => [ uri => $uri, registry => catfile($data_dir, '__metasqitch') ],
    alt_target_params => [ uri => $uri, registry => catfile($data_dir, '__sqitchtest') ],
    skip_unless => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have the right isql and can connect to the
        # database.  Adapted from the FirebirdMaker.pm module of
        # DBD::Firebird.
        my $cmd = $self->client;
        my $cmd_echo = qx(echo "quit;" | "$cmd" -z -quiet 2>&1 );
        return 0 unless $cmd_echo =~ m{Firebird}ims;
        chomp $cmd_echo;
        say "# Detected CLI $cmd_echo";
        # Skip if no DBD::Firebird.
        return 0 unless $have_fb_driver;
        say "# Connected to Firebird $fb_version" if $fb_version;
        return 1;
    },
    engine_err_regex  => qr/\QDynamic SQL Error\E/xms,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => catfile($data_dir, '__sqitchtest'),
    ),
    add_second_format => q{dateadd(1 second to %s)},
    test_dbh => sub {
        my $dbh = shift;
        # Check the session configuration...
        # To try: https://www.firebirdsql.org/refdocs/langrefupd21-intfunc-get_context.html
        is(
            $dbh->selectcol_arrayref(q{
                SELECT rdb$get_context('SYSTEM', 'DB_NAME')
                  FROM rdb$database
            })->[0],
            catfile($data_dir, '__sqitchtest'),
            'The Sqitch db should be the current db'
        );
    },
);

done_testing;
