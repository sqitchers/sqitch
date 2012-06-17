#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 192;
#use Test::More 'no_plan';
use App::Sqitch;
use App::Sqitch::Plan;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine';
    use_ok $CLASS or die;
    delete $ENV{PGDATABASE};
    delete $ENV{PGUSER};
    delete $ENV{USER};
    $ENV{SQITCH_CONFIG} = 'nonexistent.conf';
}

can_ok $CLASS, qw(load new name);

my ($is_deployed_tag, $is_deployed_step) = (0, 0);
my @deployed_steps;
my @missing_requires;
my @conflicts;
my $die = '';
my ( $latest_step, $latest_step_id, $initialized );
ENGINE: {
    # Stub out a engine.
    package App::Sqitch::Engine::whu;
    use Moose;
    use App::Sqitch::X qw(hurl);
    extends 'App::Sqitch::Engine';
    $INC{'App/Sqitch/Engine/whu.pm'} = __FILE__;

    my @SEEN;
    for my $meth (qw(
        run_file
        log_deploy_step
        log_revert_step
        log_fail_step
    )) {
        no strict 'refs';
        *$meth = sub {
            hurl 'AAAH!' if $die eq $meth;
            push @SEEN => [ $meth => $_[1] ];
        };
    }
    sub is_deployed_tag   { push @SEEN => [ is_deployed_tag   => $_[1] ]; $is_deployed_tag }
    sub is_deployed_step  { push @SEEN => [ is_deployed_step  => $_[1] ]; $is_deployed_step }
    sub check_requires    { push @SEEN => [ check_requires    => $_[1] ]; @missing_requires }
    sub check_conflicts   { push @SEEN => [ check_conflicts   => $_[1] ]; @conflicts }
    sub latest_step_id    { push @SEEN => [ latest_step_id    => $_[1] ]; $latest_step_id }
    sub initialized       { push @SEEN => 'initialized'; $initialized }
    sub initialize        { push @SEEN => 'initialize' }

    sub seen { [@SEEN] }
    after seen => sub { @SEEN = () };
}

my $uri = URI->new('https://github.com/theory/sqitch/');
ok my $sqitch = App::Sqitch->new(db_name => 'mydb', uri => $uri),
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
throws_ok { $CLASS->load({ engine => 'nonexistent', sqitch => $sqitch }) }
    'App::Sqitch::X', 'Should die on invalid engine';
is $@->message, 'Unable to load App::Sqitch::Engine::nonexistent',
    'Should get load error message';
like $@->previous_exception, qr/\QCan't locate/,
    'Should have relevant previoius exception';

NOENGINE: {
    # Test handling of no engine.
    throws_ok { $CLASS->load({ engine => '', sqitch => $sqitch }) }
        'App::Sqitch::X',
            'No engine should die';
    is $@->message, 'Missing "engine" parameter to load()',
        'It should be the expected message';
}

# Test handling a bad engine implementation.
use lib 't/lib';
throws_ok { $CLASS->load({ engine => 'bad', sqitch => $sqitch }) }
    'App::Sqitch::X', 'Should die on bad engine module';
is $@->message, 'Unable to load App::Sqitch::Engine::bad',
    'Should get another load error message';
like $@->previous_exception, qr/^LOL BADZ/,
    'Should have relevant previoius exception from the bad module';

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
    log_fail_step
    log_revert_step
    is_deployed_tag
    is_deployed_step
    check_requires
    check_conflicts
    latest_step_id
)) {
    throws_ok { $engine->$abs } qr/\Q$CLASS has not implemented $abs()/,
        "Should get an unimplemented exception from $abs()"
}

##############################################################################
# Test deploy_step and revert_step.
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Create a subclass name object again';
can_ok $engine, 'deploy_step', 'revert_step';

my $step = App::Sqitch::Plan::Step->new( name => 'foo', plan => $sqitch->plan );

ok $engine->deploy_step($step), 'Deploy a step';
is_deeply $engine->seen, [
    [check_conflicts => $step ],
    [check_requires => $step ],
    [run_file => $step->deploy_file ],
    [log_deploy_step => $step ],
], 'deploy_step should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment';

# Make it fail.
$die = 'run_file';
throws_ok { $engine->deploy_step($step) } 'App::Sqitch::X',
    'Deploy step with error';
is $@->message, 'AAAH!', 'Error should be from run_file';
is_deeply $engine->seen, [
    [check_conflicts => $step ],
    [check_requires => $step ],
    [log_fail_step => $step ],
], 'Should have logged step failure';
$die = '';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment, even with failure';

ok $engine->revert_step($step), 'Revert a step';
is_deeply $engine->seen, [
    [run_file => $step->revert_file ],
    [log_revert_step => $step ],
], 'revert_step should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  - ', 'foo'
]], 'Output should reflect reversion';

##############################################################################
# Test latest_step().
chdir 't';
my $plan_file = file qw(sql sqitch.plan);
$sqitch = App::Sqitch->new( plan_file => $plan_file, uri => $uri );
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Engine with sqitch with plan file';
my $plan = $sqitch->plan;
my @steps = $plan->steps;

$latest_step_id = $steps[0]->id;
is $engine->latest_step, $steps[0], 'Should get proper step from latest_step()';
$latest_step_id = $steps[2]->id;
is $engine->latest_step, $steps[2], 'Should again get proper step from latest_step()';
$latest_step_id = undef;

##############################################################################
# Test _sync_plan()
can_ok $CLASS, '_sync_plan';

is $plan->position, -1, 'Plan should start at position -1';
is $engine->start_at, undef, 'start_at should be undef';
ok $engine->_sync_plan, 'Sync the plan';
is $plan->position, -1, 'Plan should still be at position -1';
is $engine->start_at, undef, 'start_at should still be undef';
$plan->position(4);
ok $engine->_sync_plan, 'Sync the plan again';
is $plan->position, -1, 'Plan should again be at position -1';
is $engine->start_at, undef, 'start_at should again be undef';

# Have latest_item return a tag.
$latest_step_id = $steps[1]->id;
ok $engine->_sync_plan, 'Sync the plan to a tag';
is $plan->position, 1, 'Plan should now be at position 1';
is $engine->start_at, 'users@alpha', 'start_at should now be users@alpha';

##############################################################################
# Test deploy.
can_ok $CLASS, 'deploy';
$latest_step_id = $latest_step = undef;
$plan->reset;
$engine->seen;
my @nodes = $plan->steps;

# Mock the deploy methods to log which were called.
my $mock_engine = Test::MockModule->new($CLASS);
my $deploy_meth;
for my $meth (qw(_deploy_all _deploy_by_tag _deploy_by_step)) {
    my $orig = $CLASS->can($meth);
    $mock_engine->mock($meth => sub {
        $deploy_meth = $meth;
        $orig->(@_);
    });
}

ok $engine->deploy('@alpha'), 'Deploy to @alpha';
is $plan->position, 1, 'Plan should be at position 1';
is_deeply $engine->seen, [
    [latest_step_id => undef],
    'initialized',
    'initialize',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
], 'Should have deployed through @alpha';

is $deploy_meth, '_deploy_all', 'Should have called _deploy_all()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination} through {target}',
        destination =>  $engine->destination,
        target      => '@alpha'
    ],
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen the output of the deploy to @alpha';

# Try with no need to initialize.
$initialized = 1;
$plan->reset;
ok $engine->deploy('@alpha', 'tag'), 'Deploy to @alpha with tag mode';
is $plan->position, 1, 'Plan should again be at position 1';
is_deeply $engine->seen, [
    [latest_step_id => undef],
    'initialized',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
], 'Should have deployed through @alpha without initialization';

is $deploy_meth, '_deploy_by_tag', 'Should have called _deploy_by_tag()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination} through {target}',
        destination =>  $engine->destination,
        target      => '@alpha'
    ],
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen the output of the deploy to @alpha';

# Try a bogus target.
throws_ok { $engine->deploy('nonexistent') } 'App::Sqitch::X',
    'Should get an error for an unknown target';
is $@->message, __x(
    'Unknown deploy target: "{target}"',
    target => 'nonexistent',
), 'The exception should report the unknown target';
is_deeply $engine->seen, [
    [latest_step_id => undef],
], 'Only latest_item() should have been called';

# Start with @alpha.
$latest_step_id = ($nodes[1]->tags)[0]->id;
ok $engine->deploy('@alpha'), 'Deploy to alpha thrice';
is_deeply $engine->seen, [
    [latest_step_id => undef],
], 'Only latest_item() should have been called';
is_deeply +MockOutput->get_info, [
    [__x 'Nothing to deploy (already at "{target}"', target => '@alpha'],
], 'Should notify user that already at @alpha';

# Start with widgets.
$latest_step_id = $nodes[2]->id;
throws_ok { $engine->deploy('@alpha') } 'App::Sqitch::X',
    'Should fail targeting older node';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message,  __ 'Cannot deploy to an earlier target; use "revert" instead',
    'It should suggest using "revert"';
is_deeply $engine->seen, [
    [latest_step_id => undef],
], 'Should have called latest_item() and latest_tag()';

# Make sure we can deploy everything by step.
$latest_step_id = $latest_step = undef;
$plan->reset;
$plan->add_step('lolz');
@nodes = $plan->steps;
ok $engine->deploy(undef, 'step'), 'Deploy everything by step';
is $plan->position, 3, 'Plan should be at position 3';
is_deeply $engine->seen, [
    [latest_step_id => undef],
    'initialized',
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [log_deploy_step => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
], 'Should have deployed everything';

is $deploy_meth, '_deploy_by_step', 'Should have called _deploy_by_step()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination}', destination =>  $engine->destination ],
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen the output of the deploy to the end';

# If we deploy again, it should be up-to-date.
$latest_step_id = $nodes[-1]->id;
throws_ok { $engine->deploy } 'App::Sqitch::X',
    'Should catch exception for attempt to deploy to up-to-date DB';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __ 'Nothing to deploy (up-to-date)',
    'And the message should reflect up-to-dateness';
is_deeply $engine->seen, [
    [latest_step_id => undef],
], 'It should have just fetched the latest step ID';

$latest_step_id = undef;

# Try invalid mode.
throws_ok { $engine->deploy(undef, 'evil_mode') } 'App::Sqitch::X',
    'Should fail on invalid mode';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __x('Unknown deployment mode: "{mode}"', mode => 'evil_mode'),
    'And the message should reflect the unknown mode';
is_deeply $engine->seen, [
    [latest_step_id => undef],
    'initialized',
], 'It should have check for initialization';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying to {destination}', destination =>  $engine->destination ],
], 'Should have announced destination';

# Try a plan with no steps.
NOSTEPS: {
    my $plan_file = file qw(nonexistent.plan);
    my $sqitch = App::Sqitch->new( plan_file => $plan_file, uri => $uri );
    ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
        'Engine with sqitch with no file';
    throws_ok { $engine->deploy } 'App::Sqitch::X', 'Should die with no steps';
    is $@->message, __"Nothing to deploy (empty plan)",
        'Should have the localized message';
    is_deeply $engine->seen, [
        [latest_step_id => undef],
    ], 'It should have checked for the latest item';
}

##############################################################################
# Test _deploy_by_step()
$plan->reset;
$mock_engine->unmock('_deploy_by_step');
ok $engine->_deploy_by_step($plan, 1), 'Deploy stepwise to index 1';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
], 'Should stepwise deploy to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each node';

ok $engine->_deploy_by_step($plan, 3), 'Deploy stepwise to index 2';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [log_deploy_step => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
], 'Should stepwise deploy to from index 2 to index 3';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen output of nodes 2-3';

# Make it die.
$plan->reset;
$die = 'run_file';
throws_ok { $engine->_deploy_by_step($plan, 2) } 'App::Sqitch::X',
    'Die in _deploy_by_step';
is $@->message, 'AAAH!', 'It should have died in run_file';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_fail_step => $nodes[0] ],
], 'It should have logged the failure';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
], 'Should have seen output for first node';
$die = '';

##############################################################################
# Test _deploy_by_tag().
$plan->reset;
$mock_engine->unmock('_deploy_by_tag');
ok $engine->_deploy_by_tag($plan, 1), 'Deploy tagwise to index 1';

is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each node';

ok $engine->_deploy_by_tag($plan, 3), 'Deploy tagwise to index 3';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [log_deploy_step => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [log_deploy_step => $nodes[3]],
], 'Should tagwise deploy from index 2 to index 3';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen output of nodes 3-3';

# Add another couple of steps.
$plan->add_step('tacos');
$plan->add_step('curry');
@nodes = $plan->steps;

# Make it die.
$plan->position(1);
my $mock_whu = Test::MockModule->new('App::Sqitch::Engine::whu');
$mock_whu->mock(log_deploy_step => sub { hurl 'ROFL' if $_[1] eq $nodes[-1] });
throws_ok { $engine->_deploy_by_tag($plan, $#nodes) } 'App::Sqitch::X',
    'Die in log_deploy_step';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [run_file => $nodes[3]->deploy_file],
    [check_conflicts => $nodes[4] ],
    [check_requires => $nodes[4] ],
    [run_file => $nodes[4]->deploy_file],
    [check_conflicts => $nodes[5] ],
    [check_requires => $nodes[5] ],
    [run_file => $nodes[5]->deploy_file],
    [log_fail_step => $nodes[5] ],
    [run_file => $nodes[4]->revert_file],
    [log_revert_step => $nodes[4]],
    [run_file => $nodes[3]->revert_file],
    [log_revert_step => $nodes[3]],
], 'It should have reverted back to the last deployed tag';

is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
    ['  + ', 'tacos'],
    ['  + ', 'curry'],
    ['  - ', 'tacos'],
    ['  - ', 'lolz'],
], 'Should have seen deploy and revert messages';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting to widgets @beta']
], 'The original error should have been vented';
$mock_whu->unmock('log_deploy_step');

# Now have it fail back to the beginning.
$plan->reset;
$mock_whu->mock(run_file => sub { die 'ROFL' if $_[1]->basename eq 'users.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [log_fail_step => $nodes[1]],
    [log_revert_step => $nodes[0]],
], 'Should have logged back to the beginning';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should have seen deploy and revert messages';
my $vented = MockOutput->get_vent;
is @{ $vented }, 2, 'Should have one vented message';
my $errmsg = shift @{ $vented->[0] };
like $errmsg, qr/^ROFL\b/, 'And it should be the underlying error';
is_deeply $vented, [
    [],
    [__ 'Reverting all changes'],
], 'And it should had notified that all changes were reverted';

# Add a step and deploy to that, to make sure it rolls back any steps since
# last tag.
$plan->add_step('dr_evil');
@nodes = $plan->steps;
$plan->reset;
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'dr_evil.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag yet again';
is $@->message, __('Deploy failed'), 'Should die "Deploy failed" again';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [log_deploy_step => $nodes[1]],
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [log_deploy_step => $nodes[2]],
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [log_deploy_step => $nodes[3]],
    [check_conflicts => $nodes[4] ],
    [check_requires => $nodes[4] ],
    [log_deploy_step => $nodes[4]],
    [check_conflicts => $nodes[5] ],
    [check_requires => $nodes[5] ],
    [log_deploy_step => $nodes[5]],
    [check_conflicts => $nodes[6] ],
    [check_requires => $nodes[6] ],
    [log_fail_step => $nodes[6]],
    [log_revert_step => $nodes[5] ],
    [log_revert_step => $nodes[4] ],
    [log_revert_step => $nodes[3] ],
], 'Should have reverted back to last tag';

is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
    ['  + ', 'tacos'],
    ['  + ', 'curry'],
    ['  + ', 'dr_evil'],
    ['  - ', 'curry'],
    ['  - ', 'tacos'],
    ['  - ', 'lolz'],
], 'Should have user step reversion messages';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => 'widgets @beta']
], 'Should see underlying error and reversion message';

# Make it choke on step reversion.
$mock_whu->unmock_all;
$die = 'log_revert_step';
$plan->reset;
$mock_whu->mock(log_deploy_step => sub { hurl 'ROFL' if $_[1] eq $nodes[1] });
$mock_whu->mock(start_at => 'whatever');
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should once again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file ],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file ],
    [log_fail_step => $nodes[1] ],
    [run_file => $nodes[0]->revert_file ],
], 'Should have tried to revert one step';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should have seen revert message';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => 'whatever'],
    ['AAAH!'],
    [__ 'The schema will need to be manually repaired']
], 'Should get reversion failure message';

$die = '';
$mock_whu->unmock_all;

##############################################################################
# Test _deploy_all().
$plan->reset;
$mock_engine->unmock('_deploy_all');
ok $engine->_deploy_all($plan, 1), 'Deploy all to index 1';

is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [log_deploy_step => $nodes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each node';

ok $engine->_deploy_all($plan, 2), 'Deploy tagwise to index 2';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [log_deploy_step => $nodes[2]],
], 'Should tagwise deploy to from index 1 to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
], 'Should have seen output of nodes 3-4';

# Make it die.
$plan->reset;
$mock_whu->mock(log_deploy_step => sub { hurl 'ROFL' if $_[1] eq $nodes[2] });
throws_ok { $engine->_deploy_all($plan, 3) } 'App::Sqitch::X',
    'Die in _deploy_all';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
$mock_whu->unmock('log_deploy_step');
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [run_file => $nodes[0]->deploy_file],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [run_file => $nodes[1]->deploy_file],
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [run_file => $nodes[2]->deploy_file],
    [log_fail_step => $nodes[2]],
    [run_file => $nodes[1]->revert_file],
    [log_revert_step => $nodes[1]],
    [run_file => $nodes[0]->revert_file],
    [log_revert_step => $nodes[0]],
], 'It should have logged up to the failure';

is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  - ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should have seen deploy and revert messages';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting all changes']
], 'The original error should have been vented';
$die = '';

# Now have it fail on a later node, should still go all the way back.
$plan->reset;
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'widgets.sql' });
throws_ok { $engine->_deploy_all($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_all again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[0] ],
    [check_requires => $nodes[0] ],
    [log_deploy_step => $nodes[0]],
    [check_conflicts => $nodes[1] ],
    [check_requires => $nodes[1] ],
    [log_deploy_step => $nodes[1]],
    [check_conflicts => $nodes[2] ],
    [check_requires => $nodes[2] ],
    [log_fail_step => $nodes[2]],
    [log_revert_step => $nodes[1]],
    [log_revert_step => $nodes[0]],
], 'Should have reveted all steps and tags';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  - ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should see all steps revert';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting all changes'],
], 'Should notifiy user of error and rollback';

# Die when starting from a later point.
$plan->position(2);
$engine->start_at('@alpha');
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'dr_evil.sql' });
throws_ok { $engine->_deploy_all($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_all on the last step';
is $@->message, __('Deploy failed'), 'Should once again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $nodes[3] ],
    [check_requires => $nodes[3] ],
    [log_deploy_step => $nodes[3]],
    [check_conflicts => $nodes[4] ],
    [check_requires => $nodes[4] ],
    [log_deploy_step => $nodes[4]],
    [check_conflicts => $nodes[5] ],
    [check_requires => $nodes[5] ],
    [log_deploy_step => $nodes[5]],
    [check_conflicts => $nodes[6] ],
    [check_requires => $nodes[6] ],
    [log_fail_step => $nodes[6]],
    [log_revert_step => $nodes[5]],
    [log_revert_step => $nodes[4]],
    [log_revert_step => $nodes[3]],
], 'Should have deployed to dr_evil and revered down to @alpha';

is_deeply +MockOutput->get_info, [
    ['  + ', 'lolz'],
    ['  + ', 'tacos'],
    ['  + ', 'curry'],
    ['  + ', 'dr_evil'],
    ['  - ', 'curry'],
    ['  - ', 'tacos'],
    ['  - ', 'lolz'],
], 'Should see nodes revert back to @alpha';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => '@alpha'],
], 'Should notifiy user of error and rollback to @alpha';
$mock_whu->unmock_all;

##############################################################################
# Test is_deployed().
my $tag  = App::Sqitch::Plan::Tag->new(
    name => 'foo',
    step => $step,
    plan => $sqitch->plan,
);
$is_deployed_tag = $is_deployed_step = 1;
ok $engine->is_deployed($tag), 'Test is_deployed(tag)';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
], 'It should have called is_deployed_tag()';

ok $engine->is_deployed($step), 'Test is_deployed(step)';
is_deeply $engine->seen, [
    [is_deployed_step => $step],
], 'It should have called is_deployed_step()';

##############################################################################
# Test deploy_step.
can_ok $engine, 'deploy_step';
ok $engine->deploy_step($step), 'Deploy a step';
is_deeply $engine->seen, [
    [check_conflicts => $step],
    [check_requires => $step],
    [run_file => $step->deploy_file],
    [log_deploy_step => $step],
], 'It should have been deployed';
is_deeply +MockOutput->get_info, [
    ['  + ', $step->format_name]
], 'Should have shown step name';

# Die on conflicts.
@conflicts = qw(foo bar);
throws_ok { $engine->deploy_step($step) } 'App::Sqitch::X',
    'Conflict should throw exception';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __nx(
    'Conflicts with previously deployed step: {steps}',
    'Conflicts with previously deployed steps: {steps}',
    scalar @conflicts,
    steps => join ' ', @conflicts,
), 'Should have localized message about conflicts';

is_deeply $engine->seen, [
    [check_conflicts => $step],
], 'No other methods should have been called';
is_deeply +MockOutput->get_info, [
    ['  + ', $step->format_name]
], 'Should again have shown step name';
@conflicts = ();

# Die on missing prereqs.
@missing_requires = qw(foo bar);
throws_ok { $engine->deploy_step($step) } 'App::Sqitch::X',
    'Missing prereqs should throw exception';
is $@->ident, 'deploy', 'Should be another "deploy" error';
is $@->message, __nx(
    'Missing required step: {steps}',
    'Missing required steps: {steps}',
    scalar @missing_requires,
    steps => join ' ', @missing_requires,
), 'Should have localized message missing prereqs';

is_deeply $engine->seen, [
    [check_conflicts => $step],
    [check_requires => $step],
], 'Should have called check_requires';
is_deeply +MockOutput->get_info, [
    ['  + ', $step->format_name]
], 'Should again have shown step name';
@missing_requires = ();

# Now make it die on the actual deploy.
$die = 'log_deploy_step';
throws_ok { $engine->deploy_step($step) } 'App::Sqitch::X',
    'Shuld die on deploy failure';
is $@->message, 'AAAH!', 'Should be the underlying error';
is_deeply $engine->seen, [
    [check_conflicts => $step],
    [check_requires => $step],
    [run_file => $step->deploy_file],
    [log_fail_step => $step],
], 'It should failed to have been deployed';
is_deeply +MockOutput->get_info, [
    ['  + ', $step->format_name]
], 'Should have shown step name';

$die = '';

##############################################################################
# Test revert_step().
can_ok $engine, 'revert_step';
ok $engine->revert_step($step), 'Revert the step';
is_deeply $engine->seen, [
    [run_file => $step->revert_file],
    [log_revert_step => $step],
], 'It should have been reverted';
is_deeply +MockOutput->get_info, [
    ['  - ', $step->format_name]
], 'Should have shown reverted step name';
