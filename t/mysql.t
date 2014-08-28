#!/usr/bin/perl -w

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
    $CLASS = 'App::Sqitch::Engine::mysql';
    require_ok $CLASS or die;
    $ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.user';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.sys';}
    delete $ENV{MYSQL_PWD};


is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new(_engine => 'mysql');
isa_ok my $mysql = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'mysql' . ($^O eq 'MSWin32' ? '.exe' : '');
my $uri = URI::db->new('db:mysql:');
is $mysql->client, $client, 'client should default to mysql';
is $mysql->registry, 'sqitch', 'registry default should be "sqitch"';
my $sqitch_uri = $uri->clone;
$sqitch_uri->dbname('sqitch');
is $mysql->registry_uri, $sqitch_uri, 'registry_uri should be correct';
is $mysql->uri, $uri, qq{uri should be "$uri"};
is $mysql->registry_destination, 'db:mysql:sqitch',
    'registry_destination should be the same as registry_uri';

my @std_opts = (
    '--skip-pager',
    '--silent',
    '--skip-column-names',
    '--skip-line-numbers',
);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my $warning;
$mock_sqitch->mock(warn => sub { shift; $warning = [@_] });
is_deeply [$mysql->mysql], [$client, @std_opts],
    'mysql command should be std opts-only';
is_deeply $warning, [__x
    'Database name missing in URI "{uri}"',
     uri => $mysql->uri
], 'Should have emitted a warning for no database name';
$mock_sqitch->unmock_all;

isa_ok $mysql = $CLASS->new(
    sqitch => $sqitch,
    uri => URI::db->new('db:mysql:foo'),
), $CLASS;
ok $mysql->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$mysql->mysql], [
    $client,
    # '--foo' => 'baz',
    # '--whu' => 'hi there',
    # '--yo'  => 'stellar',
    '--database' => 'foo',
    @std_opts,
], 'Variables should not be passed to mysql';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.mysql.client'   => '/path/to/mysql',
    'core.mysql.target'   => 'db:mysql://foo.com/widgets',
    'core.mysql.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });

ok $mysql = $CLASS->new(sqitch => $sqitch), 'Create another mysql';
is $mysql->client, '/path/to/mysql', 'client should be as configured';
is $mysql->uri->as_string, 'db:mysql://foo.com/widgets',
    'URI should be as configured';
is $mysql->target, $mysql->uri->as_string, 'target should be the URI';
is $mysql->destination, $mysql->uri->as_string, 'destination should be the URI';
is $mysql->registry, 'meta', 'registry should be as configured';
is $mysql->registry_uri->as_string, 'db:mysql://foo.com/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
is $mysql->registry_destination, $mysql->registry_uri->as_string,
    'registry_destination should be the sqitch DB URL';
is_deeply [$mysql->mysql], [qw(
    /path/to/mysql
    --database widgets
    --host     foo.com
), @std_opts], 'mysql command should be configured';

##############################################################################
# Make sure the deprecated configs are also respected.
%config = (
    'core.mysql.client'    => '/path/to/mysql',
    'core.mysql.username'  => 'freddy',
    'core.mysql.password'  => 's3cr3t',
    'core.mysql.db_name'   => 'widgets',
    'core.mysql.host'      => 'db.example.com',
    'core.mysql.port'      => 1234,
    'core.mysql.registry'  => 'meta',
);

ok $mysql = $CLASS->new(sqitch => $sqitch), 'Create yet another mysql';
is $mysql->client, '/path/to/mysql', 'client should be as configured';
is $mysql->uri->as_string, 'db:mysql://freddy:s3cr3t@db.example.com:1234/widgets',
    'URI should be as configured';
is $mysql->target, $mysql->uri->as_string, 'target should be the URI string';
like $mysql->destination, qr{^db:mysql://freddy"?:\@db\.example\.com:1234/widgets$},
    'destination should be the URI minus the password';
is $mysql->registry, 'meta', 'registry should be as configured';
is $mysql->registry_uri->as_string, 'db:mysql://freddy:s3cr3t@db.example.com:1234/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
like $mysql->registry_destination, qr{^db:mysql://freddy:?\@db\.example\.com:1234/meta$},
    'registry_destination should be the sqitch DB URL sans password';
is_deeply [$mysql->mysql], [qw(
    /path/to/mysql
    --user     freddy
    --database widgets
    --host     db.example.com
    --port     1234
    --password=s3cr3t
), @std_opts], 'mysql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    _engine      => 'mysql',
    db_client   => '/some/other/mysql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $mysql = $CLASS->new(sqitch => $sqitch),
    'Create a mysql with sqitch with options';

is $mysql->client, '/some/other/mysql', 'client should be as optioned';
is $mysql->uri->as_string, 'db:mysql://anna:s3cr3t@foo.com:98760/widgets_dev',
    'The DB URI should be as optioned';
is $mysql->target, $mysql->uri->as_string, 'target should be the URI stringified';
like $mysql->destination, qr{^db:mysql://anna:?\@foo\.com:98760/widgets_dev$},
    'destination should be the URI minus the password';
is $mysql->registry, 'meta', 'registry should be as configured';
is $mysql->registry_uri->as_string, 'db:mysql://anna:s3cr3t@foo.com:98760/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
like $mysql->registry_destination, qr{^db:mysql://anna:?\@foo\.com:98760/meta$},
    'registry_destination should be the sqitch DB URL sans password';
is $mysql->registry, 'meta', 'registry should still be as configured';
is_deeply [$mysql->mysql], [qw(
    /some/other/mysql
    --user     anna
    --database widgets_dev
    --host     foo.com
    --port     98760
    --password=s3cr3t
), @std_opts], 'mysql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $mysql, qw(_run _capture _spool);
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{MYSQL_PWD}, $exp_pass, qq{MYSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{MYSQL_PWD}, 'MYSQL_PWD should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{MYSQL_PWD}, $exp_pass, qq{MYSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{MYSQL_PWD}, 'MYSQL_PWD should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{MYSQL_PWD}, $exp_pass, qq{MYSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{MYSQL_PWD}, 'MYSQL_PWD should not exist';
    }
});

$exp_pass = 's3cr3t';
ok $mysql->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $mysql->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $mysql->mysql],
    'Command should be passed to spool()';

ok $mysql->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Remove the password.
delete $config{'core.mysql.password'};
ok $mysql = $CLASS->new(sqitch => $sqitch), 'Create a mysql with sqitch with no pw';
$exp_pass = undef;
ok $mysql->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $mysql->_spool('FH'), 'Call _spool again';
is_deeply \@spool, ['FH', $mysql->mysql],
    'Command should be passed to spool() again';

ok $mysql->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $mysql->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'File should be passed to run()';

ok $mysql->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, ['FH', $mysql->mysql],
    'Handle should be passed to spool()';

# Verify should go to capture unless verosity is > 1.
ok $mysql->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'Verify file should be passed to capture()';

$mock_sqitch->mock(verbosity => 2);
ok $mysql->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';

$mock_sqitch->unmock_all;
$mock_config->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char_format';
is sprintf($CLASS->_ts2char_format, 'foo'),
    q{date_format(foo, 'year:%Y:month:%m:day:%d:hour:%H:minute:%i:second:%S:time_zone:UTC')},
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

    return unless $dbh->{Active};
    $dbh->do("DROP DATABASE IF EXISTS $_") for qw(
        __sqitchtest__
        __metasqitch
        __sqitchtest
    );
}

my $err = try {
    $mysql->use_driver;
    $dbh = DBI->connect('dbi:mysql:database=information_schema', 'root', '', {
        PrintError => 0,
        RaiseError => 1,
        AutoCommit => 1,
    });

    # Make sure we have a version we can use.
    if ($dbh->{mysql_serverinfo} =~ /mariadb/i) {
        die "MariaDB >= 50300 required; this is $dbh->{mysql_serverversion}\n"
            unless $dbh->{mysql_serverversion} >= 50300;
    }
    else {
        die "MySQL >= 50604 required; this is $dbh->{mysql_serverversion}\n"
            unless $dbh->{mysql_serverversion} >= 50604;
    }

    $dbh->do('CREATE DATABASE __sqitchtest__');
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [
        _engine     => 'mysql',
        db_username => 'root',
        db_name     => '__sqitchtest__',
        top_dir     => Path::Class::dir(qw(t engine)),
        plan_file   => Path::Class::file(qw(t engine sqitch.plan)),
    ],
    engine_params     => [ registry => '__metasqitch' ],
    alt_engine_params => [ registry => '__sqitchtest' ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have psql and can connect to the database.
        $self->sqitch->probe( $self->client, '--version' );
        $self->_capture('--execute' => 'SELECT version()');
    },
    engine_err_regex  => qr/^You have an error /,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => '__sqitchtest',
    ),
    add_second_format => q{date_add(%s, interval 1 second)},
    test_dbh => sub {
        my $dbh = shift;
        # Check the session configuration.
        for my $spec (
            [character_set_client   => 'utf8'],
            [character_set_server   => 'utf8'],
            [default_storage_engine => 'InnoDB'],
            [time_zone              => '+00:00'],
            [group_concat_max_len   => 32768],
        ) {
            is $dbh->selectcol_arrayref('SELECT @@SESSION.' . $spec->[0])->[0],
                $spec->[1], "Setting $spec->[0] should be set to $spec->[1]";
        }

        # Special-case sql_mode.
        my $sql_mode = $dbh->selectcol_arrayref('SELECT @@SESSION.sql_mode')->[0];
        for my $mode (qw(
                ansi
                strict_trans_tables
                no_auto_value_on_zero
                no_zero_date
                no_zero_in_date
                only_full_group_by
                error_for_division_by_zero
        )) {
            like $sql_mode, qr/\b\Q$mode\E\b/i, "sql_mode should include $mode";
        }
    },
);

done_testing;
