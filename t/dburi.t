#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use Path::Class qw(dir file);
use App::Sqitch;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

PACKAGE: {
    package App::Sqitch::Thing;
    use Mouse;
    has sqitch => ( is => 'ro', isa => 'App::Sqitch', required => 1 );
    with 'App::Sqitch::Role::DBURI';
}

can_ok 'App::Sqitch::Thing', 'db_uri';
my @sqitch_params = (
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
);

##############################################################################
# Test with no engine.
my $sqitch = App::Sqitch->new(@sqitch_params);

isa_ok my $thing = App::Sqitch::Thing->new({ sqitch => $sqitch }),
    'App::Sqitch::Thing', 'Thing';
throws_ok { $thing->db_uri } 'App::Sqitch::X',
    'Should get an exception when no engine';
is $@->ident, 'core', 'No _engine error ident should be "core"';
is $@->message, __ 'No engine specified; use --engine or set core.engine',
    'No _engine error message should be correct';

##############################################################################
# Test with an engine.
$sqitch = App::Sqitch->new(@sqitch_params, _engine => 'sqlite');
isa_ok $thing = App::Sqitch::Thing->new({ sqitch => $sqitch }),
    'App::Sqitch::Thing', 'Thing with SQLite engine';
isa_ok my $uri = $thing->db_uri, 'URI::db', 'SQLite URI';
is $uri->as_string, 'db:sqlite:', 'SQLite URI should be correct';

# Different engine.
$sqitch = App::Sqitch->new(@sqitch_params, _engine => 'pg');
isa_ok $thing = App::Sqitch::Thing->new({ sqitch => $sqitch }),
    'App::Sqitch::Thing', 'Thing with Pg engine';
isa_ok $uri = $thing->db_uri, 'URI::db', 'Pg URI';
is $uri->as_string, 'db:pg:', 'Pg URI should be correct';

##############################################################################
# Add some other attributes.
push @sqitch_params, _engine => 'pg';
for my $spec (
    [ 'host only', [ db_host => 'localhost' ], 'db:pg://localhost' ],
    [ 'host and port', [ db_host => 'foo', db_port => 3333 ], 'db:pg://foo:3333' ],
    [ 'username', [ db_username => 'fred' ], 'db:pg://fred@' ],
    [ 'db name', [ db_name => 'try' ], 'db:pg:try' ],
    [
        'host and db name',
        [ db_host => 'foo.com', db_name => '/try.db' ],
        'db:pg://foo.com//try.db',
    ],
    [
        'all parts',
        [ db_host => 'foo.us', db_port => 2, db_username => 'al', db_name => 'blah' ],
        'db:pg://al@foo.us:2/blah',
    ]
) {
    my ($desc, $params, $uri) = @{ $spec };
    my $sqitch = App::Sqitch->new(@sqitch_params, @{ $params });
    isa_ok my $thing = App::Sqitch::Thing->new({ sqitch => $sqitch }),
    'App::Sqitch::Thing', "Thing with $desc";
    is $thing->db_uri->as_string, $uri, "Default URI with $desc should be correct";
}

##############################################################################
# Make sure URIs passed to the construtor get merged, too.
$sqitch = App::Sqitch->new(@sqitch_params, db_name => 'foo');
isa_ok $thing = App::Sqitch::Thing->new({
    sqitch => $sqitch,
    db_uri => URI->new('db:pg:blah'),
}), 'App::Sqitch::Thing', 'Thing with URI';
is $thing->db_uri->as_string, 'db:pg:foo', 'DB name should be merged into URI';

$sqitch = App::Sqitch->new(@sqitch_params, db_name => 'foo', db_host => 'foo.com');
isa_ok $thing = App::Sqitch::Thing->new({
    sqitch => $sqitch,
    db_uri => URI->new('db:pg://localhost/blah'),
}), 'App::Sqitch::Thing', 'Thing with full URI';
is $thing->db_uri->as_string, 'db:pg://foo.com/foo',
    'DB host and name should be merged into URI';

done_testing;
