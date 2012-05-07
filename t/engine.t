#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 23;

#use Test::More 'no_plan';
use App::Sqitch;
use Test::Exception;
use Test::NoWarnings;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(load new name);

ENGINE: {

    # Stub out a engine.
    package App::Sqitch::Engine::whu;
    use Moose;
    extends 'App::Sqitch::Engine';
    $INC{'App/Sqitch/Engine/whu.pm'} = __FILE__;
}

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';

##############################################################################
# Test new().
throws_ok { $CLASS->new }
qr/\QAttribute (sqitch) is required/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new( { sqitch => $array } ) }
qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new( { sqitch => 'foo' } ) }
qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for string sqitch param';

isa_ok $CLASS->new( { sqitch => $sqitch } ), $CLASS;

##############################################################################
# Test load().
ok my $cmd = $CLASS->load( {
        sqitch => $sqitch,
        engine => 'whu',
    }
    ),
    'Load a "whu" engine';
isa_ok $cmd, 'App::Sqitch::Engine::whu';
is $cmd->sqitch, $sqitch, 'The sqitch attribute should be set';

# Test handling of an invalid engine.
$0 = 'sqch';
throws_ok { $CLASS->load( { engine => 'nonexistent', sqitch => $sqitch } ) }
qr/\QCan't locate/, 'Should die on invalid engine';

NOENGINE: {

    # Test handling of no engine.
    throws_ok { $CLASS->load( { engine => '', sqitch => $sqitch } ) }
    qr/\QMissing "engine" parameter to load()/,
        'No engine should die';
}

# Test handling a bad engine implementation.
use lib 't/lib';
throws_ok { $CLASS->load( { engine => 'bad', sqitch => $sqitch } ) }
qr/^LOL BADZ/, 'Should die on bad engine module';

##############################################################################
# Test name.
can_ok $CLASS, 'name';
ok $cmd = $CLASS->new( { sqitch => $sqitch } ), "Create a $CLASS object";
is $CLASS->name, '', 'Base class name should be ""';
is $cmd->name,   '', 'Base object name should be ""';

ok $cmd = App::Sqitch::Engine::whu->new( { sqitch => $sqitch } ),
    'Create a subclass name object';
is $cmd->name, 'whu', 'Subclass oject name should be "whu"';
is +App::Sqitch::Engine::whu->name, 'whu',
    'Subclass class name should be "whu"';

##############################################################################
# Test config_vars.
can_ok 'App::Sqitch::Engine', 'config_vars';
is_deeply [ App::Sqitch::Engine->config_vars ], [],
    'Should have no config vars in engine base class';

