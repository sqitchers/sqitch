#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use Path::Class qw(dir file);
use App::Sqitch;
use Test::Exception;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Engine;

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

can_ok 'App::Sqitch::Engine', 'uri';
my @sqitch_params = (
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
);

##############################################################################
# Test with no engine.
my $sqitch = App::Sqitch->new(@sqitch_params);

isa_ok my $engine = App::Sqitch::Engine->new({ sqitch => $sqitch }),
    'App::Sqitch::Engine', 'Engine';
throws_ok { $engine->uri } 'App::Sqitch::X',
    'Should get an exception when no engine';
is $@->ident, 'engine', 'No _engine error ident should be "core"';
is $@->message, __ 'No engine specified; use --engine or set core.engine',
    'No _engine error message should be correct';

##############################################################################
# Test with an engine.
$sqitch = App::Sqitch->new(@sqitch_params, _engine => 'sqlite');
isa_ok $engine = $sqitch->engine, 'App::Sqitch::Engine::sqlite', 'SQLite Engine';
isa_ok my $uri = $engine->uri, 'URI::db', 'SQLite URI';
is $uri->as_string, 'db:sqlite:sql.db', 'SQLite URI should be correct';

# Different engine.
$sqitch = App::Sqitch->new(@sqitch_params, _engine => 'pg');
isa_ok $engine = $sqitch->engine, 'App::Sqitch::Engine', 'Engine with Pg engine';
isa_ok $uri = $engine->uri, 'URI::db', 'Pg URI';
is $uri->as_string, 'db:pg:', 'Pg URI should be correct';

##############################################################################
# Test with configuration keys.
CONFIG: {
    my $mock_config = Test::MockModule->new('App::Sqitch::Config');
    my @config_params;
    my @config_ret = ('db:sqlite:hi');
    $mock_config->mock(get => sub { shift; @config_params = @_; shift @config_ret });
    my $e = $sqitch->engine;
    is $e->uri, URI->new('db:sqlite:hi'),
        'URI should be the default for the engine';
    is_deeply \@config_params, [key => 'core.pg.target'],
        'Should have asked for the Pg default target';

    # Test with key that contains another key.
    my $mock_sqitch = Test::MockModule->new('App::Sqitch');
    my @sqitch_params;
    my $sqitch_ret = { uri => URI::db->new('db:pg:yo'), target => 'db:pg:yo' };
    $mock_sqitch->mock(config_for_target_strict => sub { shift; @sqitch_params = @_; $sqitch_ret });
    @config_ret = ('yo');

    $e = $sqitch->engine;
    is $e->uri, $sqitch_ret->{uri}, 'URI should be from the target lookup';
    is_deeply \@config_params, [key => 'core.pg.target'],
        'Should have asked for the Pg default target again';
    is_deeply \@sqitch_params, ['yo'], 'Should have looked up the "yo" database';

    # Test with uri configuration key.
    @config_ret = (undef, 'db:pg:');
    $e = $sqitch->engine;
    is $e->uri, URI->new('db:pg:'),
        'URI should get the engine-specific config key';
    is_deeply \@config_params, [key => 'core.pg.uri'],
        'Should have asked for the Pg default uri';
}

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
    isa_ok my $engine = $sqitch->engine, 'App::Sqitch::Engine', "Engine with $desc";
    is $engine->uri->as_string, $uri, "Default URI with $desc should be correct";
}

##############################################################################
# Make sure URIs passed to the construtor get merged.
$sqitch = App::Sqitch->new(@sqitch_params, db_name => 'foo');
isa_ok $engine = App::Sqitch::Engine->new({
    sqitch => $sqitch,
    uri => URI->new('db:pg:blah'),
}), 'App::Sqitch::Engine', 'Engine with URI';
is $engine->uri->as_string, 'db:pg:foo', 'DB name should be merged into URI';

$sqitch = App::Sqitch->new(@sqitch_params, db_name => 'foo', db_host => 'foo.com');
isa_ok $engine = App::Sqitch::Engine->new({
    sqitch => $sqitch,
    uri => URI->new('db:pg://localhost:1234/blah'),
}), 'App::Sqitch::Engine', 'Engine with full URI';
is $engine->uri->as_string, 'db:pg://foo.com:1234/foo',
    'DB host and name should be merged into URI';

done_testing;
