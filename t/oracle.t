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
use App::Sqitch::Plan;
use lib 't/lib';
use DBIEngineTest;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::oracle';
    require_ok $CLASS or die;
    $ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.conf';
    $ENV{SQITCH_USER_CONFIG}   = 'nonexistent.conf';
    delete $ENV{ORACLE_HOME};
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
isa_ok my $ora = $CLASS->new(sqitch => $sqitch), $CLASS;

my $client = 'sqlplus' . ($^O eq 'MSWin32' ? '.exe' : '');
is $ora->client, $client, 'client should default to sqlplus';
ORACLE_HOME: {
    local $ENV{ORACLE_HOME} = '/foo/bar';
    isa_ok my $ora = $CLASS->new(sqitch => $sqitch), $CLASS;
    is $ora->client, Path::Class::file('/foo/bar', $client)->stringify,
        'client should use $ORACLE_HOME';
}

is $ora->sqitch_schema, undef, 'sqitch_schema default should be undefined';
for my $attr (qw(username password db_name host port)) {
    is $ora->$attr, undef, "$attr default should be undef";
}

is $ora->destination, $ENV{TWO_TASK}
                   || $^O eq 'MSWin32' ? $ENV{LOCAL} : undef
                   || $ENV{ORACLE_SID}
                   || $sqitch->sysuser,
    'Destination should fall back on environment variables';
is $ora->meta_destination, $ora->destination,
    'Meta destination should be the same as destination';

is_deeply [$ora->sqlplus], [$client, qw(-S -L /nolog)],
    'sqlplus command should connect to /nolog';

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect ',
) ), '_script should work';

# Set up username, password, and db_name.
isa_ok my $ora = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf',
    db_name  => 'blah',
), $CLASS;

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect fred/"derf"@"blah"',
) ), '_script should assemble connection string';

# Add a host name.
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf',
    db_name  => 'blah',
    host     => 'there',
), $CLASS;

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'connect fred/"derf"@//there/"blah"',
) ), '_script should assemble connection string with host';

# Add a port and varibles.
isa_ok $ora = $CLASS->new(
    sqitch => $sqitch,
    username => 'fred',
    password => 'derf "derf"',
    db_name  => 'blah "blah"',
    host     => 'there',
    port     => 1345,
), $CLASS;
ok $ora->set_variables(foo => 'baz', whu => 'hi there', yo => q{"stellar"}),
    'Set some variables';

is $ora->_script, join( "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        'DEFINE foo="baz"',
        'DEFINE whu="hi there"',
        'DEFINE yo="""stellar"""',
        'connect fred/"derf ""derf"""@//there:1345/"blah ""blah"""',
) ), '_script should assemble connection string with host, port, and vars';

done_testing;
