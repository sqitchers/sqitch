#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
#use Test::More tests => 23;
use Test::More 'no_plan';
use App::Sqitch;
use App::Sqitch::Plan;
use Test::Exception;
use Test::NoWarnings;
use lib 't/lib';
use MockOutput;

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

    my @SEEN;
    sub run_file        { push @SEEN => [ run_file        => $_[1] ] }
    sub run_handle      { push @SEEN => [ run_handle      => $_[1] ] }
    sub log_deploy_step { push @SEEN => [ log_deploy_step => $_[1] ] }
    sub log_revert_step { push @SEEN => [ log_revert_step => $_[1] ] }
    sub log_deploy_tag  { push @SEEN => [ log_deploy_tag  => $_[1] ] }
    sub log_revert_tag  { push @SEEN => [ log_revert_tag  => $_[1] ] }

    sub seen { [@SEEN] }
    after seen => sub { @SEEN = () };
}

ok my $sqitch = App::Sqitch->new(db_name => 'mydb'),
    'Load a sqitch sqitch object';

##############################################################################
# Test new().
throws_ok { $CLASS->new }
    qr/\QAttribute (sqitch) is required/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new({ sqitch => $array }) }
    qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new({ sqitch => 'foo' }) }
    qr/\QValidation failed for 'App::Sqitch' with value/,
    'Should get an exception for string sqitch param';

isa_ok $CLASS->new({sqitch => $sqitch}), $CLASS;

##############################################################################
# Test load().
ok my $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
}), 'Load a "whu" engine';
isa_ok $engine, 'App::Sqitch::Engine::whu';
is $engine->sqitch, $sqitch, 'The sqitch attribute should be set';

# Test handling of an invalid engine.
$0 = 'sqch';
throws_ok { $CLASS->load({ engine => 'nonexistent', sqitch => $sqitch }) }
    qr/\QCan't locate/, 'Should die on invalid engine';

NOENGINE: {
    # Test handling of no engine.
    throws_ok { $CLASS->load({ engine => '', sqitch => $sqitch }) }
        qr/\QMissing "engine" parameter to load()/,
            'No engine should die';
}

# Test handling a bad engine implementation.
use lib 't/lib';
throws_ok { $CLASS->load({ engine => 'bad', sqitch => $sqitch }) }
    qr/^LOL BADZ/, 'Should die on bad engine module';

##############################################################################
# Test name.
can_ok $CLASS, 'name';
ok $engine = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
is $CLASS->name, '', 'Base class name should be ""';
is $engine->name, '', 'Base object name should be ""';

ok $engine = App::Sqitch::Engine::whu->new({sqitch => $sqitch}),
    'Create a subclass name object';
is $engine->name, 'whu', 'Subclass oject name should be "whu"';
is +App::Sqitch::Engine::whu->name, 'whu', 'Subclass class name should be "whu"';

##############################################################################
# Test config_vars.
can_ok 'App::Sqitch::Engine', 'config_vars';
is_deeply [App::Sqitch::Engine->config_vars], [],
    'Should have no config vars in engine base class';

##############################################################################
# Test abstract methods.
ok $engine = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object again";
for my $abs (qw(
   initialized
   initialize
   run_file
   run_handle
   log_deploy_step
   log_revert_step
   log_deploy_tag
   log_revert_tag
)) {
    throws_ok { $engine->$abs } qr/\Q$CLASS has not implemented $abs()/,
        "Should get an unimplemented exception from $abs()"
}

##############################################################################
# Test deploy_step and revert_step.
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Create a subclass name object again';
can_ok $engine, 'deploy_step', 'revert_step';

my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
my $tag  = App::Sqitch::Plan::Tag->new( names  => ['foo'], plan => $plan );
my $step = App::Sqitch::Plan::Step->new( name => 'foo',  tag  => $tag );

ok $engine->deploy_step($step), 'Deploy a step';
is_deeply $engine->seen, [
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
], 'deploy_step should have called the proper methods';

ok $engine->revert_step($step), 'Revert a step';
is_deeply $engine->seen, [
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
], 'revert_step should have called the proper methods';

##############################################################################
# Test deploy.
can_ok $CLASS, 'deploy';
ok $engine->deploy($tag), 'Deploy a tag with no steps';
is_deeply +MockOutput->get_info, [['Deploying ', 'foo', ' to ', 'mydb']],
    'Should get info message about tag deployment';
is_deeply +MockOutput->get_warn, [
    ['Tag ', $tag->name, ' has no steps; skipping']
], 'Should get warning about no steps';

# Add a step to this tag.
push @{ $tag->_steps } => $step;
ok $engine->deploy($tag), 'Deploy tag with a single step';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
], 'Should get info message about tag and step deployment';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
is_deeply $engine->seen, [
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
    [log_deploy_tag => $tag ],
], 'The step and tag should have been deployed and logged';

# Add a second step.
my $step2 = App::Sqitch::Plan::Step->new( name => 'bar',  tag  => $tag );
push @{ $tag->_steps } => $step2;
ok $engine->deploy($tag), 'Deploy tag with two steps';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
], 'Should get info message about tag and both step deployments';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
is_deeply $engine->seen, [
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
    [run_file => $step2->deploy_file ],
    [log_deploy_step => $step2 ],
    [log_deploy_tag => $tag ],
], 'Both steps and the tag should have been deployed and logged';

# Die on the first step.
my $crash_in = 1;
my $mock = Test::MockModule->new(ref $engine, no_auto => 1);
$mock->mock(deploy_step => sub { die 'OMGWTFLOL' if --$crash_in == 0; });

throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
], 'Should get info message about tag and first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
my $debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'And it should be the original error';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';

# Try bailing on the second step.
$crash_in = 2;
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die again';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message again';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'And it should again be the original error';
is_deeply +MockOutput->get_vent, [
    ['Reverting previous steps for tag ', $tag->name]
], 'The reversion should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';

# Now choke on a reversion, too (add insult to injury).
$crash_in = 2;
$mock->mock(revert_step => sub { die 'OWOWOW' });
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die thrice';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of first step';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 2, 'Should have two debug messages';
like $debug->[0][0], qr/^OMGWTFLOL\b/, 'The first should be the original error';
like $debug->[1][0], qr/^OWOWOW\b/, 'The second should be the revert error';
is_deeply +MockOutput->get_vent, [
    [ 'Reverting previous steps for tag ', $tag->name],
    [ 'Error reverting step ', $step->name, $/,
      'The schema will need to be manually repaired'
    ],
], 'The reversion and its failure should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';

# Now get all the way through, but choke when tagging.
$mock->unmock_all;
$mock->mock(log_deploy_tag => sub { die 'WHYME!' });
throws_ok { $engine->deploy($tag) } qr/^FAIL\b/, 'Should die on bad tag';
is_deeply +MockOutput->get_info, [
    ['Deploying ', 'foo', ' to ', 'mydb'],
    ['  + ', $step->name ],
    ['  + ', $step2->name ],
    ['  - ', $step2->name ],
    ['  - ', $step->name ],
], 'Should get info message including reversion of both steps';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';
$debug = MockOutput->get_debug;
is @{ $debug }, 1, 'Should have one debug message';
like $debug->[0][0], qr/^WHYME!/, 'And it should be the original error';
is_deeply +MockOutput->get_vent, [
    [ 'Reverting previous steps for tag ', $tag->name],
], 'The reversion should have been vented';
is_deeply +MockOutput->get_fail, [
    ['Aborting deployment of ', $tag->name ]
], 'Should have the final failure message';
