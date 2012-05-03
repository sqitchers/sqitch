#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use Test::More tests => 27;
#use Test::More 'no_plan';
use Test::MockModule;
use App::Sqitch;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::pg';
    require_ok $CLASS or die;
}

is_deeply [$CLASS->config_vars], [
    client        => 'any',
    username      => 'any',
    password      => 'any',
    db_name       => 'any',
    host          => 'any',
    port          => 'int',
    sqitch_schema => 'any',
], 'config_vars should return three vars';

my $sqitch = App::Sqitch->new;
isa_ok my $pg = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'psql' . ($^O eq 'Win32' ? '.exe' : '');
is $pg->client, $client, 'client should default to psql';
is $pg->sqitch_schema, 'sqitch', 'sqitch_schema default should be "sqitch"';
for my $attr (qw(username password db_name host port)) {
    is $pg->$attr, undef, "$attr default should be undef";
}
is_deeply [$pg->psql], [$client], 'psql command should be client-only';

##############################################################################
# Make sure config settings override defaults.
my %config = (
    'core.pg.client'        => '/path/to/psql',
    'core.pg.username'      => 'freddy',
    'core.pg.password'      => 's3cr3t',
    'core.pg.db_name'       => 'widgets',
    'core.pg.host'          => 'db.example.com',
    'core.pg.port'          => 1234,
    'core.pg.sqitch_schema' => 'meta',
);
my $mock_config = Test::MockModule->new('App::Sqitch::Config');
$mock_config->mock(get => sub { $config{ $_[2] } });
ok $pg = $CLASS->new(sqitch => $sqitch), 'Create another pg';

is $pg->client, '/path/to/psql', 'client should be as configured';
is $pg->username, 'freddy', 'username should be as configured';
is $pg->password, 's3cr3t', 'password should be as configured';
is $pg->host, 'db.example.com', 'host should be as configured';
is $pg->port, 1234, 'port should be as configured';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should be as configured';
is_deeply [$pg->psql], [qw(
    /path/to/psql
    --username freddy
    --dbname   widgets
    --host     db.example.com
    --port     1234
)], 'psql command should be configured';

##############################################################################
# Now make sure that Sqitch options override configurations.
$sqitch = App::Sqitch->new(
    'client'        => '/some/other/psql',
    'username'      => 'anna',
    'db_name'       => 'widgets_dev',
    'host'          => 'foo.com',
    'port'          => 98760,
);

ok $pg = $CLASS->new(sqitch => $sqitch), 'Create a pg with sqitch with options';

is $pg->client, '/some/other/psql', 'client should be as optioned';
is $pg->username, 'anna', 'username should be as optioned';
is $pg->password, 's3cr3t', 'password should still be as configured';
is $pg->host, 'foo.com', 'host should be as optioned';
is $pg->port, 98760, 'port should be as optioned';
is $pg->sqitch_schema, 'meta', 'sqitch_schema should still be as configured';
is_deeply [$pg->psql], [qw(
    /some/other/psql
    --username anna
    --dbname   widgets_dev
    --host     foo.com
    --port     98760
)], 'psql command should be as optioned';
