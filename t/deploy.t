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

my $CLASS = 'App::Sqitch::Command::deploy';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    options
    configure
    new
    to_target
    mode
    execute
);

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    top_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);

isa_ok my $deploy = $CLASS->new(sqitch => $sqitch), $CLASS;

is $deploy->to_target, undef, 'to_target should be undef';
is $deploy->mode, 'all', 'mode should be "all"';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(deploy => sub { shift; @args = @_ });

ok $deploy->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@args, ['@alpha', 'all'],
    '"@alpha" and "all" should be passed to the engine';

@args = ();
ok $deploy->execute, 'Execute';
is_deeply \@args, [undef, 'all'],
    'undef and "all" should be passed to the engine';

isa_ok $deploy = $CLASS->new(
    sqitch    => $sqitch,
    to_target => 'foo',
    mode      => 'tag',
), $CLASS, 'Object with to and mode';


@args = ();
ok $deploy->execute, 'Execute again';
is_deeply \@args, ['foo', 'tag'],
    '"foo" and "tag" should be passed to the engine';

# Make sure the mode enum works.
for my $mode (qw(all tag change)) {
    ok $CLASS->new( sqitch => $sqitch, mode => $mode ),
        qq{"$mode" should be a valid mode};
}

for my $bad (qw(foo bad gar)) {
    throws_ok { $CLASS->new( sqitch => $sqitch, mode => $bad ) } qr/Validation failed/,
        qq{"$bad" should not be a valid mode};
}

done_testing;
