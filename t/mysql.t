#!/usr/bin/perl -w

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

my $sqitch = App::Sqitch->new( options => { engine => 'mysql'} );
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
isa_ok my $mysql = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $mysql->key, 'mysql', 'Key should be "mysql"';
is $mysql->name, 'MySQL', 'Name should be "MySQL"';

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
    ($^O eq 'MSWin32' ? () : '--skip-pager' ),
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

$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri => URI::db->new('db:mysql:foo'),
);
isa_ok $mysql = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'engine.mysql.client'   => '/path/to/mysql',
    'engine.mysql.target'   => 'db:mysql://foo.com/widgets',
    'engine.mysql.registry' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
my $mysql_version = 'mysql  Ver 15.1 Distrib 10.0.15-MariaDB';
$mock_sqitch->mock(probe => sub { $mysql_version });

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another mysql';
is $mysql->client, '/path/to/mysql', 'client should be as configured';
is $mysql->uri->as_string, 'db:mysql://foo.com/widgets',
    'URI should be as configured';
is $mysql->target->name, $mysql->uri->as_string, 'target name should be the URI';
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
# Make sure URI params get passed through to the client.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:mysql://foo.com/widgets?' . join(
        '&',
        'mysql_compression=1',
        'mysql_ssl=1',
        'mysql_connect_timeout=20',
        'mysql_init_command=BEGIN',
        'mysql_socket=/dev/null',
        'mysql_ssl_client_key=/foo/key',
        'mysql_ssl_client_cert=/foo/cert',
        'mysql_ssl_ca_file=/foo/cafile',
        'mysql_ssl_ca_path=/foo/capath',
        'mysql_ssl_cipher=blowfeld',
        'mysql_client_found_rows=20',
        'mysql_foo=bar',
    ),
));
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a mysql with query params';
is_deeply [$mysql->mysql], [qw(
    /path/to/mysql
    --database widgets
    --host     foo.com
), @std_opts, qw(
    --compress
    --ssl
    --connect_timeout 20
    --init-command BEGIN
    --socket /dev/null
    --ssl-key /foo/key
    --ssl-cert /foo/cert
    --ssl-ca /foo/cafile
    --ssl-capath /foo/capath
    --ssl-cipher blowfeld
)], 'mysql command should be configured with query vals';

$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:mysql://foo.com/widgets?' . join(
        '&',
        'mysql_compression=0',
        'mysql_ssl=0',
        'mysql_connect_timeout=20',
        'mysql_client_found_rows=20',
        'mysql_foo=bar',
    ),
));
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a mysql with disabled query params';
is_deeply [$mysql->mysql], [qw(
    /path/to/mysql
    --database widgets
    --host     foo.com
), @std_opts, qw(
    --connect_timeout 20
)], 'mysql command should not have disabled param options';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    options => {
        engine   => 'mysql',
        client   => '/some/other/mysql',
    },
);

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a mysql with sqitch with options';

is $mysql->client, '/some/other/mysql', 'client should be as optioned';
is $mysql->registry, 'meta', 'registry should be as configured';
is $mysql->registry_uri->as_string, 'db:mysql://foo.com/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
is $mysql->registry_destination, 'db:mysql://foo.com/meta',
    'registry_destination should be the sqitch DB URL sans password';
is $mysql->registry, 'meta', 'registry should still be as configured';
is_deeply [$mysql->mysql], [qw(
    /some/other/mysql
    --database widgets
    --host     foo.com
), @std_opts], 'mysql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $mysql, qw(_run _capture _spool);
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
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
    local $Test::Builder::Level = $Test::Builder::Level + 2;
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
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{MYSQL_PWD}, $exp_pass, qq{MYSQL_PWD should be "$exp_pass"};
    } else {
        ok !exists $ENV{MYSQL_PWD}, 'MYSQL_PWD should not exist';
    }
});

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a mysql with sqitch with options';
$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $mysql->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $mysql->_spool('FH'), 'Call _spool';
is_deeply \@spool, [['FH'], $mysql->mysql],
    'Command should be passed to spool()';
$mysql->set_variables(foo => 'bar', '"that"' => "'this'");
ok $mysql->_spool('FH'), 'Call _spool with variables';
ok my $fh = shift @{ $spool[0] }, 'Get variables file handle';
is_deeply \@spool, [['FH'], $mysql->mysql],
    'Command should be passed to spool() after variables handle';
is join("\n", <$fh>), qq{SET \@"""that""" = '''this''', \@"foo" = 'bar';\n},
    'Variables should have been escaped and set';
$mysql->clear_variables;

ok $mysql->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $mysql = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a mysql with sqitch with no pw';
$exp_pass = undef;
$target->uri->password($exp_pass);
ok $mysql->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $mysql->_spool('FH'), 'Call _spool again';
is_deeply \@spool, [['FH'], $mysql->mysql],
    'Command should be passed to spool() again';

ok $mysql->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $mysql->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'File should be passed to run()';
@run = ();

ok $mysql->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, [['FH'], $mysql->mysql],
    'Handle should be passed to spool()';
@spool = ();

# Verify should go to capture unless verosity is > 1.
ok $mysql->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'Verify file should be passed to capture()';
@capture = ();

$mock_sqitch->mock(verbosity => 2);
ok $mysql->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$mysql->mysql, '--execute', 'source foo/bar.sql'],
    'Verifile file should be passed to run() for high verbosity';
@run = ();

# Try with variables.
$mysql->set_variables(foo => 'bar', '"that"' => "'this'");
my $set = qq{SET \@"""that""" = '''this''', \@"foo" = 'bar';\n};

ok $mysql->run_file('foo/bar.sql'), 'Run foo/bar.sql with vars';
is_deeply \@run, [$mysql->mysql, '--execute', "${set}source foo/bar.sql"],
    'Variabls and file should be passed to run()';
@run = ();

ok $mysql->run_handle('FH'), 'Spool a "file handle"';
ok $fh = shift @{ $spool[0] }, 'Get variables file handle';
is_deeply \@spool, [['FH'], $mysql->mysql],
    'File handle should be passed to spool() after variables handle';
is join("\n", <$fh>), $set, 'Variables should have been escaped and set';
@spool = ();

ok $mysql->run_verify('foo/bar.sql'), 'Verbosely verify foo/bar.sql with vars';
is_deeply \@run, [$mysql->mysql, '--execute', "${set}source foo/bar.sql"],
    'Variables and verify file should be passed to run()';
@run = ();

# Reset verbosity to send verify to spool.
$mock_sqitch->unmock('verbosity');
ok $mysql->run_verify('foo/bar.sql'), 'Verify foo/bar.sql with vars';
is_deeply \@capture, [$mysql->mysql, '--execute', "${set}source foo/bar.sql"],
    'Verify file should be passed to capture()';
@capture = ();

$mysql->clear_variables;
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

my $db = '__sqitchtest__' . $$;
my $reg1 = '__metasqitch' . $$;
my $reg2 = '__sqitchtest' . $$;

END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    return unless $dbh->{Active};
    $dbh->do("DROP DATABASE IF EXISTS $_") for ($db, $reg1, $reg2);
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
        die "MySQL >= 50000 required; this is $dbh->{mysql_serverversion}\n"
            unless $dbh->{mysql_serverversion} >= 50000;
    }

    $dbh->do("CREATE DATABASE $db");
    undef;
} catch {
    eval { $_->message } || $_;
};

DBIEngineTest->run(
    class         => $CLASS,
    sqitch_params => [options => {
        engine      => 'mysql',
        top_dir     => Path::Class::dir(qw(t engine))->stringify,
        plan_file   => Path::Class::file(qw(t engine sqitch.plan))->stringify,
    }],
    target_params     => [
        registry => $reg1,
        uri => URI::db->new("db:mysql://root@/$db"),
    ],
    alt_target_params => [
        registry => $reg2,
        uri => URI::db->new("db:mysql://root@/$db"),
    ],
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
        database => $reg2,
    ),
    add_second_format => q{date_add(%s, interval 1 second)},
    test_dbh => sub {
        my $dbh = shift;
        # Check the session configuration.
        for my $spec (
            [character_set_client   => 'utf8'],
            [character_set_server   => 'utf8'],
            ($dbh->{mysql_serverversion} < 50500 ? () : ([default_storage_engine => 'InnoDB'])),
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
