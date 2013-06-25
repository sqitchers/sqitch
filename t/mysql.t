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
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $mysql = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'mysql' . ($^O eq 'MSWin32' ? '.exe' : '');
is $mysql->client, $client, 'client should default to mysql';
is $mysql->sqitch_db, 'sqitch', 'sqitch_db default should be "sqitch"';
for my $attr (qw(username password db_name host port destination meta_destination)) {
    is $mysql->$attr, undef, "$attr default should be undef";
}

my @std_opts = (
    '--skip-pager',
    '--silent',
    '--skip-column-names',
    '--skip-line-numbers',
);
is_deeply [$mysql->mysql], [$client, @std_opts],
    'mysql command should be std opts-only';

isa_ok $mysql = $CLASS->new(sqitch => $sqitch), $CLASS;
ok $mysql->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$mysql->mysql], [
    $client,
    '--foo' => 'baz',
    '--whu' => 'hi there',
    '--yo'  => 'stellar',
    @std_opts,
], 'Variables should be passed to mysql via --$key';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.mysql.client'    => '/path/to/mysql',
    'core.mysql.username'  => 'freddy',
    'core.mysql.password'  => 's3cr3t',
    'core.mysql.db_name'   => 'widgets',
    'core.mysql.host'      => 'db.example.com',
    'core.mysql.port'      => 1234,
    'core.mysql.sqitch_db' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $mysql = $CLASS->new(sqitch => $sqitch), 'Create another mysql';

is $mysql->client, '/path/to/mysql', 'client should be as configured';
is $mysql->username, 'freddy', 'username should be as configured';
is $mysql->password, 's3cr3t', 'password should be as configured';
is $mysql->db_name, 'widgets', 'db_name should be as configured';
is $mysql->destination, 'widgets', 'destination should default to db_name';
is $mysql->meta_destination, 'widgets', 'meta_destination should default to db_name';
is $mysql->host, 'db.example.com', 'host should be as configured';
is $mysql->port, 1234, 'port should be as configured';
is $mysql->sqitch_db, 'meta', 'sqitch_db should be as configured';
is_deeply [$mysql->mysql], [qw(
    /path/to/mysql
    --user     freddy
    --password s3cr3t
    --database widgets
    --host     db.example.com
    --port     1234
), @std_opts], 'mysql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    db_client   => '/some/other/mysql',
    db_username => 'anna',
    db_name     => 'widgets_dev',
    db_host     => 'foo.com',
    db_port     => 98760,
);

ok $mysql = $CLASS->new(sqitch => $sqitch), 'Create a mysql with sqitch with options';

is $mysql->client, '/some/other/mysql', 'client should be as optioned';
is $mysql->username, 'anna', 'username should be as optioned';
is $mysql->password, 's3cr3t', 'password should still be as configured';
is $mysql->db_name, 'widgets_dev', 'db_name should be as optioned';
is $mysql->destination, 'widgets_dev', 'destination should still default to db_name';
is $mysql->meta_destination, 'widgets_dev', 'meta_destination should still default to db_name';
is $mysql->host, 'foo.com', 'host should be as optioned';
is $mysql->port, 98760, 'port should be as optioned';
is $mysql->sqitch_db, 'meta', 'sqitch_db should still be as configured';
is_deeply [$mysql->mysql], [qw(
    /some/other/mysql
    --user     anna
    --password s3cr3t
    --database widgets_dev
    --host     foo.com
    --port     98760
), @std_opts], 'mysql command should be as optioned';

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $mysql, qw(_run _capture _spool);
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my @run;
$mock_sqitch->mock(run => sub { shift; @run = @_; });

my @capture;
$mock_sqitch->mock(capture => sub { shift; @capture = @_; });

my @spool;
$mock_sqitch->mock(spool => sub { shift; @spool = @_; });

ok $mysql->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to run()';

ok $mysql->_spool('FH'), 'Call _spool';
is_deeply \@spool, ['FH', $mysql->mysql],
    'Command should be passed to spool()';

ok $mysql->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$mysql->mysql, qw(foo bar baz)],
    'Command should be passed to capture()';

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

done_testing;
