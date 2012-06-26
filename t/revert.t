#!/usr/bin/perl

use strict;
use warnings;
use v5.10;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::revert';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    to_target
    execute
);

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);

isa_ok my $revert = $CLASS->new(sqitch => $sqitch), $CLASS;

is $revert->to_target, undef, 'to_target should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(revert => sub { shift; @args = @_ });

ok $revert->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@args, ['@alpha'],
    '"@alpha" and "all" should be passed to the engine';

@args = ();
ok $revert->execute, 'Execute';
is_deeply \@args, [undef],
    'undef and "all" should be passed to the engine';

isa_ok $revert = $CLASS->new(
    sqitch    => $sqitch,
    to_target => 'foo',
), $CLASS, 'Object with to';


@args = ();
ok $revert->execute, 'Execute again';
is_deeply \@args, ['foo'],
    '"foo" and "tag" should be passed to the engine';

done_testing;
