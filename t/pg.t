#!/usr/bin/perl -w

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

BEGIN {
    $CLASS = 'App::Sqitch::Engine::pg';
    require_ok $CLASS or die;
    $ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.user';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.sys';
    delete $ENV{PGPASSWORD};
}


is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:pg:');
my $sqitch = App::Sqitch->new(options => { engine => 'pg' });
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => $uri,
);
isa_ok my $pg = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

my $client = 'psql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $pg->client, $client, 'client should default to psql';
is $pg->registry, 'sqitch', 'registry default should be "sqitch"';
is $pg->uri, $uri, 'DB URI should be "db:pg:"';
my $dest_uri = $uri->clone;
$dest_uri->dbname($ENV{PGDATABASE} || $ENV{PGUSER} || $sqitch->sysuser);
is $pg->destination, $dest_uri->as_string,
    'Destination should fall back on environment variables';
is $pg->registry_destination, $pg->destination,
    'Registry destination should be the same as destination';

my @std_opts = (
    '--quiet',
    '--no-psqlrc',
    '--no-align',
    '--tuples-only',
    '--set' => 'ON_ERROR_STOP=1',
    '--set' => 'registry=sqitch',
);
is_deeply [$pg->psql], [$client, @std_opts],
    'psql command should be std opts-only';

isa_ok $pg = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
ok $pg->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$pg->psql], [
    $client,
    '--set' => 'foo=baz',
    '--set' => 'whu=hi there',
    '--set' => 'yo=stellar',
    @std_opts,
], 'Variables should be passed to psql via --set';

##############################################################################
# Test other configs for the target.
ENV: {
    # Make sure we override system-set vars.
    local $ENV{PGDATABASE};
    local $ENV{PGUSER};
    for my $env (qw(PGDATABASE PGUSER)) {
        my $pg = $CLASS->new(sqitch => $sqitch, target => $target);
        local $ENV{$env} = "\$ENV=whatever";
        is $pg->target->uri, "db:pg:", "Target should not read \$$env";
        is $pg->registry_destination, $pg->destination,
            'Meta target should be the same as destination';
    }

    my $mocker = Test::MockModule->new('App::Sqitch');
    $mocker->mock(sysuser => 'sysuser=whatever');
    my $pg = $CLASS->new(sqitch => $sqitch, target => $target);
    is $pg->target->uri, 'db:pg:', 'Target should not fall back on sysuser';
    is $pg->registry_destination, $pg->destination,
        'Meta target should be the same as destination';

    $ENV{PGDATABASE} = 'mydb';
    $pg = $CLASS->new(sqitch => $sqitch, username => 'hi', target => $target);
    is $pg->target->uri, 'db:pg:',  'Target should be the default';
    is $pg->registry_destination, $pg->destination,
        'Meta target should be the same as destination';
}

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.pg.client'   => '/path/to/psql',
    'engine.pg.target'   => 'db:pg://localhost/try',
    'engine.pg.registry' => 'meta',
);
$std_opts[-1] = 'registry=meta';
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $pg = $CLASS->new(sqitch => $sqitch, target => $target), 'Create another pg';
is $pg->client, '/path/to/psql', 'client should be as configured';
is $pg->uri->as_string, 'db:pg://localhost/try',
    'uri should be as configured';
is $pg->registry, 'meta', 'registry should be as configured';
is_deeply [$pg->psql], [qw(
    /path/to/psql
    --dbname   try
    --host     localhost
), @std_opts], 'psql command should be configured from URI config';

##############################################################################
# Now make sure that (deprecated?) Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    options => {
        engine => 'pg',
        client => '/some/other/psql',
    }
);

$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $pg = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a pg with sqitch with options';

is $pg->client, '/some/other/psql', 'client should be as optioned';
is $pg->registry_destination, $pg->destination,
    'registry_destination should be the same as destination';
is $pg->registry, 'meta', 'registry should still be as configured';
is_deeply [$pg->psql], [qw(
    /some/other/psql
    --dbname   try
    --host     localhost
), @std_opts], 'psql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $pg, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{PGPASSWORD}, $exp_pass, qq{PGPASSWORD should be "$exp_pass"};
    } else {
        ok !exists $ENV{PGPASSWORD}, 'PGPASSWORD should not exist';
    }
});

$target->uri->password('s3cr3t');
$exp_pass = 's3cr3t';
ok $pg->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $pg->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool()';

ok $pg->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Remove the password.
$target->uri->password(undef);
ok $pg = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a pg with sqitch with no pw';
$exp_pass = undef;
ok $pg->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $pg->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $pg->psql],
    'Command should be passed to spool() again';

ok $pg->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$pg->psql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $pg->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'File should be passed to run()';

ok $pg->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $pg->psql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $pg->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$pg->psql, '--file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $pg->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$pg->psql, '--file', 'foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
ok my $ts2char = $CLASS->can('_ts2char'), "$CLASS->can('_ts2char')";
is $ts2char->('foo'),
    q{to_char(foo AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')},
    '_ts2char should work';

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

    $dbh->do('DROP DATABASE __sqitchtest__') if $dbh->{Active};
}

my $err = try {
    $pg->use_driver;
    $dbh = DBI->connect('dbi:Pg:dbname=template1', 'postgres', '', {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });
    $dbh->do($_) for (
        'CREATE DATABASE __sqitchtest__',
        q{ALTER DATABASE __sqitchtest__ SET lc_messages = 'C'},
    );
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [options => {
        engine     => 'pg',
        top_dir     => Path::Class::dir(qw(t engine))->stringify,
        plan_file   => Path::Class::file(qw(t engine sqitch.plan))->stringify,
    }],
    target_params => [
        uri => URI::db->new('db:pg://postgres@/__sqitchtest__'),
    ],
    alt_target_params => [
        registry => '__sqitchtest',
        uri => URI::db->new('db:pg://postgres@/__sqitchtest__'),
    ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have psql and can connect to the database.
        $self->sqitch->probe( $self->client, '--version' );
        $self->_capture('--command' => 'SELECT version()');
    },
    engine_err_regex  => qr/^ERROR:  /,
    init_error        => __x(
        'Sqitch schema "{schema}" already exists',
        schema => '__sqitchtest',
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the first in the search path.
        is $dbh->selectcol_arrayref('SELECT current_schema')->[0],
            '__sqitchtest', 'The Sqitch schema should be the current schema';
    },
);

done_testing;
