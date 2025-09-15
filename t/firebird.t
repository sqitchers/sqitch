#!/usr/bin/perl -w
#
# To test against a live Firebird database, you must set the
# SQITCH_TEST_FIREBIRD_URI environment variable. this is a standard URI::db URI,
# and should look something like this:
#
#     export SQITCH_TEST_FIREBIRD_URI=db:firebird://sysdba:password@localhost//path/to/test.db
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
use DBD::Mem;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;
my $uri;
my $tmpdir;
my $have_fb_driver = 1; # assume DBD::Firebird is installed and so is Firebird

# Is DBD::Firebird really installed?
try { require DBD::Firebird; } catch { $have_fb_driver = 0; };

BEGIN {
    $CLASS = 'App::Sqitch::Engine::firebird';
    require_ok $CLASS or die;
    $uri = URI->new($ENV{SQITCH_TEST_FIREBIRD_URI} || $ENV{FIREBIRD_URI} || do {
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
is $fb->_limit_default, '18446744073709551615', 'Should have _limit_default';
is $fb->_dsn, 'dbi:Firebird:dbname=sqitch.fdb;ib_dialect=3;ib_charset=UTF8',
    'Should append "ib_dialect=3;ib_charset=UTF8" to the DSN';

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

# Verify should go to capture unless verbosity is > 1.
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
# Test error checking functions.
DBI: {
    local *DBI::errstr;
    ok !$fb->_no_table_error, 'Should have no table error';
    ok !$fb->_no_column_error, 'Should have no column error';

    $DBI::errstr = '-Table unknown';
    ok $fb->_no_table_error, 'Should now have table error';
    ok !$fb->_no_column_error, 'Still should have no column error';

    $DBI::errstr = 'No such file or directory';
    ok $fb->_no_table_error, 'Should again have table error';
    ok !$fb->_no_column_error, 'Still should have no column error';

    $DBI::errstr = '-Column unknown';
    ok !$fb->_no_table_error, 'Should again have no table error';
    ok $fb->_no_column_error, 'Should now have no column error';
}

##############################################################################
# Test database creation failure.
DBFAIL: {
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(initialized => 0);
    $mock->mock(use_driver => 1);
    my $fbmock = Test::MockModule->new('DBD::Firebird', no_auto => 1);
    $fbmock->mock(create_database => sub { die 'Creation failed' });
    throws_ok { $fb->initialize } 'App::Sqitch::X',
        'Should get an error from initialize';
    is $@->ident, 'firebird', 'No creattion exception ident should be "firebird"';
    my $msg = __x(
        'Cannot create database {database}: {error}',
        database => $fb->connection_string($fb->registry_uri),
        error => 'Creation failed',
    );
    like $@->message, qr{^\Q$msg\E}, 'Creation exception message should be correct';
}

##############################################################################
# Test various database connection and error-handling logic.
DBH: {
    # Need to mock DBH.
    my $dbh = DBI->connect('dbi:Mem:', undef, undef, {});
    my $mock_engine = Test::MockModule->new($CLASS);
    $mock_engine->mock(dbh => $dbh);
    $mock_engine->mock(registry_uri => URI->new('db:firebird:foo.fdb'));
    my $mock_dbd = Test::MockModule->new(ref $dbh, no_auto => 1);
    my ($disconnect, $clear);
    $mock_dbd->mock(disconnect => sub { $disconnect = 1 });
    $mock_engine->mock(_clear_dbh => sub { $clear = 1 });
    my $run;
    $mock_sqitch->mock(run => sub { $run = 1 });

    # Test that upgrading disconnects from a local database before upgrading.
    ok $fb->run_upgrade('somefile'), 'Run the upgrade';
    ok $disconnect, 'Should have disconnected';
    ok $clear, 'Should have cleared the database handle';
    ok $run, 'Should have run a command';
    $mock_sqitch->unmock('run');

    # Test that _cid propagates an unexpected error from DBI.
    local *DBI::err;
    $DBI::err = 0;
    $mock_engine->mock(dbh => sub { die 'Oops' });
    throws_ok { $fb->_cid('ASC', 0, 'foo') } qr/^Oops/,
        '_cid should propagate unexpected error';

    # But it should just return for error code -902.
    $DBI::err = -902;
    lives_ok { $fb->_cid('ASC', 0, 'foo') }
        '_cid should just return on error code -902';

    # Test that current_state returns on no table error.
    local *DBI::errstr;
    $DBI::errstr = '-Table unknown';
    $mock_engine->mock(initialized => 0);
    lives_ok { $fb->current_state('foo') }
        'current_state should return on no table error';

    # But it should die if it's not a table error.
    $DBI::errstr = 'Some other error';
    throws_ok { $fb->current_state('foo') } qr/^Oops/,
        'current_state should propagate unexpected error';

    # Make sure change_id_for returns undef when no useful params.
    $mock_engine->mock(dbh => $dbh);
    is $fb->change_id_for(project => 'foo'), undef,
        'Should get undef from change_id_for when no useful params';
}

# Make sure default_client croaks when it finds no client.
FSPEC: {
    # Give it an invalid fbsql file to find.
    my $tmpdir = tempdir(CLEANUP => 1);
    my $tmp = Path::Class::Dir->new("$tmpdir");
    my $iswin = App::Sqitch::ISWIN || $^O eq 'cygwin';
    my $fbsql = $tmp->file('fbsql' . ($iswin ? '.exe' : ''));
    $fbsql->touch;
    chmod 0755, $fbsql unless $iswin;

    my $fs_mock = Test::MockModule->new('File::Spec');
    $fs_mock->mock(path => sub { $tmp });
    throws_ok { $fb->default_client } 'App::Sqitch::X',
        'Should get error when no client found';
    is $@->ident, 'firebird', 'Client exception ident should be "firebird"';
    is $@->message, __(
        'Unable to locate Firebird ISQL; set "engine.firebird.client" via sqitch config'
    ), 'Client exception message should be correct';
}

# Make sure we have templates.
DBIEngineTest->test_templates_for($fb->key);

##############################################################################
# Can we do live tests?
my ($data_dir, $fb_version, @cleanup) = ($tmpdir);
my $id = DBIEngineTest->randstr;
my ($reg1, $reg2) = map { $_ . $id } qw(__sqitchreg_ __metasqitch_);
my $err = try {
    return unless $have_fb_driver;
    if ($uri->dbname) {
        $data_dir = dirname $uri->dbname; # Assumes local OS semantics.
    } else {
        # Assume we're running locally and create the database.
        my $dbpath = catfile($tmpdir, "__sqitchtest__$id");
        $data_dir = $tmpdir;
        $uri->dbname($dbpath);
        DBD::Firebird->create_database({
            db_path       => $dbpath,
            user          => $uri->user,
            password      => $uri->password,
            character_set => 'UTF8',
            page_size     => 16384,
        });
        # We created this database, we need to clean it up.
        @cleanup = ($dbpath);
    }

    # Try to connect.
    my $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError  => 0,
        RaiseError  => 0,
        AutoCommit  => 1,
        HandleError => $fb->error_handler,
    });
    $fb_version = $dbh->selectcol_arrayref(q{
        SELECT rdb$get_context('SYSTEM', 'ENGINE_VERSION')
          FROM rdb$database
    })->[0];

    # We will need to clean up the registry DBs we create.
    push @cleanup => map { catfile $data_dir, $_ } $reg1, $reg2;
    return undef;
} catch {
    return $_ if blessed $_ && $_->isa('App::Sqitch::X');
    return App::Sqitch::X->new(
        message            => 'Failed to connect to Firebird',
        previous_exception => $_,
    ),
};

END {
    return if $ENV{CI}; # No need to clean up in CI environment.
    foreach my $dbname (@cleanup) {
        next unless -e $dbname;
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
    target_params     => [ uri => $uri, registry => catfile($data_dir, $reg1) ],
    alt_target_params => [ uri => $uri, registry => catfile($data_dir, $reg2) ],
    skip_unless => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have the right isql and can connect to the
        # database.  Adapted from the FirebirdMaker.pm module of
        # DBD::Firebird.
        my $cmd = $self->client;
        my $cmd_echo = qx(echo "quit;" | "$cmd" -z -quiet 2>&1 );
        App::Sqitch::X::hurl('isql not for Firebird')
             unless $cmd_echo =~ m{Firebird}ims;
        chomp $cmd_echo;
        say "# Detected $cmd_echo";
        # Skip if no DBD::Firebird.
        App::Sqitch::X::hurl('DBD::Firebird did not load')
            unless $have_fb_driver;
        say "# Connected to Firebird $fb_version" if $fb_version;
        return 1;
    },
    engine_err_regex  => qr/\QDynamic SQL Error\E/xms,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => catfile($data_dir, $reg2),
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
            catfile($data_dir, $reg2),
            'The Sqitch db should be the current db'
        );
    },
);

done_testing;
