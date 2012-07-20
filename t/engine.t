#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 230;
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

my ($is_deployed_tag, $is_deployed_change) = (0, 0);
my @deployed_change_ids;
my @missing_requires;
my @conflicts;
my $die = '';
my $record_work = 1;
my ( $latest_change, $latest_change_id, $initialized );
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
        log_deploy_change
        log_revert_change
        log_fail_change
    )) {
        no strict 'refs';
        *$meth = sub {
            hurl 'AAAH!' if $die eq $meth;
            push @SEEN => [ $meth => $_[1] ];
        };
    }
    sub is_deployed_tag   { push @SEEN => [ is_deployed_tag   => $_[1] ]; $is_deployed_tag }
    sub is_deployed_change  { push @SEEN => [ is_deployed_change  => $_[1] ]; $is_deployed_change }
    sub check_requires    { push @SEEN => [ check_requires    => $_[1] ]; @missing_requires }
    sub check_conflicts   { push @SEEN => [ check_conflicts   => $_[1] ]; @conflicts }
    sub latest_change_id    { push @SEEN => [ latest_change_id    => $_[1] ]; $latest_change_id }
    sub initialized       { push @SEEN => 'initialized'; $initialized }
    sub initialize        { push @SEEN => 'initialize' }
    sub deployed_change_ids { push @SEEN => [ deployed_change_ids => $_[1] ]; @deployed_change_ids }
    sub deployed_change_ids_since { push @SEEN => [ deployed_change_ids_since => $_[1] ]; @deployed_change_ids }
    sub begin_work        { push @SEEN => ['begin_work']  if $record_work }
    sub finish_work       { push @SEEN => ['finish_work'] if $record_work }

    sub seen { [@SEEN] }
    after seen => sub { @SEEN = () };

    sub name_for_change_id { return 'bugaboo' }
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
    log_deploy_change
    log_fail_change
    log_revert_change
    is_deployed_tag
    is_deployed_change
    check_requires
    check_conflicts
    latest_change_id
    deployed_change_ids
    deployed_change_ids_since
    name_for_change_id
    current_state
    current_changes
    current_tags
    search_events
)) {
    throws_ok { $engine->$abs } qr/\Q$CLASS has not implemented $abs()/,
        "Should get an unimplemented exception from $abs()"
}

##############################################################################
# Test deploy_change and revert_change.
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Create a subclass name object again';
can_ok $engine, 'deploy_change', 'revert_change';

my $change = App::Sqitch::Plan::Change->new( name => 'foo', plan => $sqitch->plan );

ok $engine->deploy_change($change), 'Deploy a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [check_conflicts => $change ],
    [check_requires => $change ],
    [run_file => $change->deploy_file ],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'deploy_change should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment';

# Make it fail.
$die = 'run_file';
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Deploy change with error';
is $@->message, 'AAAH!', 'Error should be from run_file';
is_deeply $engine->seen, [
    ['begin_work'],
    [check_conflicts => $change ],
    [check_requires => $change ],
    [log_fail_change => $change ],
    ['finish_work'],
], 'Should have logged change failure';
$die = '';
is_deeply +MockOutput->get_info, [[
    '  + ', 'foo'
]], 'Output should reflect the deployment, even with failure';

ok $engine->revert_change($change), 'Revert a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->revert_file ],
    [log_revert_change => $change ],
    ['finish_work'],
], 'revert_change should have called the proper methods';
is_deeply +MockOutput->get_info, [[
    '  - ', 'foo'
]], 'Output should reflect reversion';
$record_work = 0;

##############################################################################
# Test latest_change().
chdir 't';
my $plan_file = file qw(sql sqitch.plan);
my $sqitch_old = $sqitch; # Hang on to this because $change does not retain it.
$sqitch = App::Sqitch->new( plan_file => $plan_file, uri => $uri );
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Engine with sqitch with plan file';
my $plan = $sqitch->plan;
my @changes = $plan->changes;

$latest_change_id = $changes[0]->id;
is $engine->latest_change, $changes[0], 'Should get proper change from latest_change()';
$latest_change_id = $changes[2]->id;
is $engine->latest_change, $changes[2], 'Should again get proper change from latest_change()';
$latest_change_id = undef;

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
$latest_change_id = $changes[1]->id;
ok $engine->_sync_plan, 'Sync the plan to a tag';
is $plan->position, 1, 'Plan should now be at position 1';
is $engine->start_at, 'users@alpha', 'start_at should now be users@alpha';

##############################################################################
# Test deploy.
can_ok $CLASS, 'deploy';
$latest_change_id = $latest_change = undef;
$plan->reset;
$engine->seen;
@changes = $plan->changes;

# Mock the deploy methods to log which were called.
my $mock_engine = Test::MockModule->new($CLASS);
my $deploy_meth;
for my $meth (qw(_deploy_all _deploy_by_tag _deploy_by_change)) {
    my $orig = $CLASS->can($meth);
    $mock_engine->mock($meth => sub {
        $deploy_meth = $meth;
        $orig->(@_);
    });
}

ok $engine->deploy('@alpha'), 'Deploy to @alpha';
is $plan->position, 1, 'Plan should be at position 1';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
    'initialize',
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should have deployed through @alpha';

is $deploy_meth, '_deploy_all', 'Should have called _deploy_all()';
is_deeply +MockOutput->get_info, [
    [__x 'Adding metadata tables to {destination}',
        destination => $engine->destination,
    ],
    [__x 'Deploying changes through {target} to {destination}',
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
    [latest_change_id => undef],
    'initialized',
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should have deployed through @alpha without initialization';

is $deploy_meth, '_deploy_by_tag', 'Should have called _deploy_by_tag()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying changes through {target} to {destination}',
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
    [latest_change_id => undef],
], 'Only latest_item() should have been called';

# Start with @alpha.
$latest_change_id = ($changes[1]->tags)[0]->id;
ok $engine->deploy('@alpha'), 'Deploy to alpha thrice';
is_deeply $engine->seen, [
    [latest_change_id => undef],
], 'Only latest_item() should have been called';
is_deeply +MockOutput->get_info, [
    [__x 'Nothing to deploy (already at "{target}"', target => '@alpha'],
], 'Should notify user that already at @alpha';

# Start with widgets.
$latest_change_id = $changes[2]->id;
throws_ok { $engine->deploy('@alpha') } 'App::Sqitch::X',
    'Should fail targeting older change';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message,  __ 'Cannot deploy to an earlier target; use "revert" instead',
    'It should suggest using "revert"';
is_deeply $engine->seen, [
    [latest_change_id => undef],
], 'Should have called latest_item() and latest_tag()';

# Make sure we can deploy everything by change.
$latest_change_id = $latest_change = undef;
$plan->reset;
$plan->add( name => 'lolz' );
@changes = $plan->changes;
ok $engine->deploy(undef, 'change'), 'Deploy everything by change';
is $plan->position, 3, 'Plan should be at position 3';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should have deployed everything';

is $deploy_meth, '_deploy_by_change', 'Should have called _deploy_by_change()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying changes to {destination}', destination =>  $engine->destination ],
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen the output of the deploy to the end';

# If we deploy again, it should be up-to-date.
$latest_change_id = $changes[-1]->id;
throws_ok { $engine->deploy } 'App::Sqitch::X',
    'Should catch exception for attempt to deploy to up-to-date DB';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __ 'Nothing to deploy (up-to-date)',
    'And the message should reflect up-to-dateness';
is_deeply $engine->seen, [
    [latest_change_id => undef],
], 'It should have just fetched the latest change ID';

$latest_change_id = undef;

# Try invalid mode.
throws_ok { $engine->deploy(undef, 'evil_mode') } 'App::Sqitch::X',
    'Should fail on invalid mode';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __x('Unknown deployment mode: "{mode}"', mode => 'evil_mode'),
    'And the message should reflect the unknown mode';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
], 'It should have check for initialization';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying changes to {destination}', destination =>  $engine->destination ],
], 'Should have announced destination';

# Try a plan with no changes.
NOSTEPS: {
    my $plan_file = file qw(empty.plan);
    my $fh = $plan_file->open('>') or die "Cannot open $plan_file: $!";
    say $fh '%project=empty';
    $fh->close or die "Error closing $plan_file: $!";
    END { $plan_file->remove }
    my $sqitch = App::Sqitch->new( plan_file => $plan_file, uri => $uri );
    ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
        'Engine with sqitch with no file';
    throws_ok { $engine->deploy } 'App::Sqitch::X', 'Should die with no changes';
    is $@->message, __"Nothing to deploy (empty plan)",
        'Should have the localized message';
    is_deeply $engine->seen, [
        [latest_change_id => undef],
    ], 'It should have checked for the latest item';
}

##############################################################################
# Test _deploy_by_change()
$plan->reset;
$mock_engine->unmock('_deploy_by_change');
ok $engine->_deploy_by_change($plan, 1), 'Deploy changewise to index 1';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should changewise deploy to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each change';

ok $engine->_deploy_by_change($plan, 3), 'Deploy changewise to index 2';
is_deeply $engine->seen, [
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should changewise deploy to from index 2 to index 3';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen output of changes 2-3';

# Make it die.
$plan->reset;
$die = 'run_file';
throws_ok { $engine->_deploy_by_change($plan, 2) } 'App::Sqitch::X',
    'Die in _deploy_by_change';
is $@->message, 'AAAH!', 'It should have died in run_file';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [log_fail_change => $changes[0] ],
], 'It should have logged the failure';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
], 'Should have seen output for first change';
$die = '';

##############################################################################
# Test _deploy_by_tag().
$plan->reset;
$mock_engine->unmock('_deploy_by_tag');
ok $engine->_deploy_by_tag($plan, 1), 'Deploy tagwise to index 1';

is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each change';

ok $engine->_deploy_by_tag($plan, 3), 'Deploy tagwise to index 3';
is_deeply $engine->seen, [
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should tagwise deploy from index 2 to index 3';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
    ['  + ', 'lolz'],
], 'Should have seen output of changes 3-3';

# Add another couple of changes.
$plan->add(name => 'tacos' );
$plan->add(name => 'curry' );
@changes = $plan->changes;

# Make it die.
$plan->position(1);
my $mock_whu = Test::MockModule->new('App::Sqitch::Engine::whu');
$mock_whu->mock(log_deploy_change => sub { hurl 'ROFL' if $_[1] eq $changes[-1] });
throws_ok { $engine->_deploy_by_tag($plan, $#changes) } 'App::Sqitch::X',
    'Die in log_deploy_change';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [run_file => $changes[3]->deploy_file],
    [check_conflicts => $changes[4] ],
    [check_requires => $changes[4] ],
    [run_file => $changes[4]->deploy_file],
    [check_conflicts => $changes[5] ],
    [check_requires => $changes[5] ],
    [run_file => $changes[5]->deploy_file],
    [log_fail_change => $changes[5] ],
    [run_file => $changes[4]->revert_file],
    [log_revert_change => $changes[4]],
    [run_file => $changes[3]->revert_file],
    [log_revert_change => $changes[3]],
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
$mock_whu->unmock('log_deploy_change');

# Now have it fail back to the beginning.
$plan->reset;
$mock_whu->mock(run_file => sub { die 'ROFL' if $_[1]->basename eq 'users.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [log_fail_change => $changes[1]],
    [log_revert_change => $changes[0]],
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

# Add a change and deploy to that, to make sure it rolls back any changes since
# last tag.
$plan->add(name => 'dr_evil' );
@changes = $plan->changes;
$plan->reset;
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'dr_evil.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag yet again';
is $@->message, __('Deploy failed'), 'Should die "Deploy failed" again';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [log_deploy_change => $changes[1]],
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [log_deploy_change => $changes[2]],
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [log_deploy_change => $changes[3]],
    [check_conflicts => $changes[4] ],
    [check_requires => $changes[4] ],
    [log_deploy_change => $changes[4]],
    [check_conflicts => $changes[5] ],
    [check_requires => $changes[5] ],
    [log_deploy_change => $changes[5]],
    [check_conflicts => $changes[6] ],
    [check_requires => $changes[6] ],
    [log_fail_change => $changes[6]],
    [log_revert_change => $changes[5] ],
    [log_revert_change => $changes[4] ],
    [log_revert_change => $changes[3] ],
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
], 'Should have user change reversion messages';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => 'widgets @beta']
], 'Should see underlying error and reversion message';

# Make it choke on change reversion.
$mock_whu->unmock_all;
$die = '';
$plan->reset;
$mock_whu->mock(run_file => sub {
     hurl 'ROFL' if $_[1] eq $changes[1]->deploy_file;
     hurl 'BARF' if $_[1] eq $changes[0]->revert_file;
});
$mock_whu->mock(start_at => 'whatever');
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should once again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [log_deploy_change => $changes[0] ],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [log_fail_change => $changes[1] ],
], 'Should have tried to revert one change';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should have seen revert message';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => 'whatever'],
    ['BARF'],
    [__ 'The schema will need to be manually repaired']
], 'Should get reversion failure message';
$mock_whu->unmock_all;

##############################################################################
# Test _deploy_all().
$plan->reset;
$mock_engine->unmock('_deploy_all');
ok $engine->_deploy_all($plan, 1), 'Deploy all to index 1';

is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
], 'Should have seen output of each change';

ok $engine->_deploy_all($plan, 2), 'Deploy tagwise to index 2';
is_deeply $engine->seen, [
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
], 'Should tagwise deploy to from index 1 to index 2';
is_deeply +MockOutput->get_info, [
    ['  + ', 'widgets @beta'],
], 'Should have seen output of changes 3-4';

# Make it die.
$plan->reset;
$mock_whu->mock(log_deploy_change => sub { hurl 'ROFL' if $_[1] eq $changes[2] });
throws_ok { $engine->_deploy_all($plan, 3) } 'App::Sqitch::X',
    'Die in _deploy_all';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
$mock_whu->unmock('log_deploy_change');
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [run_file => $changes[0]->deploy_file],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [run_file => $changes[1]->deploy_file],
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [run_file => $changes[2]->deploy_file],
    [log_fail_change => $changes[2]],
    [run_file => $changes[1]->revert_file],
    [log_revert_change => $changes[1]],
    [run_file => $changes[0]->revert_file],
    [log_revert_change => $changes[0]],
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

# Now have it fail on a later change, should still go all the way back.
$plan->reset;
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'widgets.sql' });
throws_ok { $engine->_deploy_all($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_all again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $changes[0] ],
    [check_requires => $changes[0] ],
    [log_deploy_change => $changes[0]],
    [check_conflicts => $changes[1] ],
    [check_requires => $changes[1] ],
    [log_deploy_change => $changes[1]],
    [check_conflicts => $changes[2] ],
    [check_requires => $changes[2] ],
    [log_fail_change => $changes[2]],
    [log_revert_change => $changes[1]],
    [log_revert_change => $changes[0]],
], 'Should have reveted all changes and tags';
is_deeply +MockOutput->get_info, [
    ['  + ', 'roles'],
    ['  + ', 'users @alpha'],
    ['  + ', 'widgets @beta'],
    ['  - ', 'users @alpha'],
    ['  - ', 'roles'],
], 'Should see all changes revert';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting all changes'],
], 'Should notifiy user of error and rollback';

# Die when starting from a later point.
$plan->position(2);
$engine->start_at('@alpha');
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'dr_evil.sql' });
throws_ok { $engine->_deploy_all($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_all on the last change';
is $@->message, __('Deploy failed'), 'Should once again get final deploy failure message';
is_deeply $engine->seen, [
    [check_conflicts => $changes[3] ],
    [check_requires => $changes[3] ],
    [log_deploy_change => $changes[3]],
    [check_conflicts => $changes[4] ],
    [check_requires => $changes[4] ],
    [log_deploy_change => $changes[4]],
    [check_conflicts => $changes[5] ],
    [check_requires => $changes[5] ],
    [log_deploy_change => $changes[5]],
    [check_conflicts => $changes[6] ],
    [check_requires => $changes[6] ],
    [log_fail_change => $changes[6]],
    [log_revert_change => $changes[5]],
    [log_revert_change => $changes[4]],
    [log_revert_change => $changes[3]],
], 'Should have deployed to dr_evil and revered down to @alpha';

is_deeply +MockOutput->get_info, [
    ['  + ', 'lolz'],
    ['  + ', 'tacos'],
    ['  + ', 'curry'],
    ['  + ', 'dr_evil'],
    ['  - ', 'curry'],
    ['  - ', 'tacos'],
    ['  - ', 'lolz'],
], 'Should see changes revert back to @alpha';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {target}', target => '@alpha'],
], 'Should notifiy user of error and rollback to @alpha';
$mock_whu->unmock_all;

##############################################################################
# Test is_deployed().
my $tag  = App::Sqitch::Plan::Tag->new(
    name => 'foo',
    change => $change,
    plan => $sqitch->plan,
);
$is_deployed_tag = $is_deployed_change = 1;
ok $engine->is_deployed($tag), 'Test is_deployed(tag)';
is_deeply $engine->seen, [
    [is_deployed_tag => $tag],
], 'It should have called is_deployed_tag()';

ok $engine->is_deployed($change), 'Test is_deployed(change)';
is_deeply $engine->seen, [
    [is_deployed_change => $change],
], 'It should have called is_deployed_change()';

##############################################################################
# Test deploy_change.
can_ok $engine, 'deploy_change';
ok $engine->deploy_change($change), 'Deploy a change';
is_deeply $engine->seen, [
    [check_conflicts => $change],
    [check_requires => $change],
    [run_file => $change->deploy_file],
    [log_deploy_change => $change],
], 'It should have been deployed';
is_deeply +MockOutput->get_info, [
    ['  + ', $change->format_name]
], 'Should have shown change name';

# Die on conflicts.
@conflicts = qw(foo bar);
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Conflict should throw exception';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message, __nx(
    'Conflicts with previously deployed change: {changes}',
    'Conflicts with previously deployed changes: {changes}',
    scalar @conflicts,
    changes => join ' ', @conflicts,
), 'Should have localized message about conflicts';

is_deeply $engine->seen, [
    [check_conflicts => $change],
], 'No other methods should have been called';
is_deeply +MockOutput->get_info, [
    ['  + ', $change->format_name]
], 'Should again have shown change name';
@conflicts = ();

# Die on missing dependencies.
@missing_requires = qw(foo bar);
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Missing dependencies should throw exception';
is $@->ident, 'deploy', 'Should be another "deploy" error';
is $@->message, __nx(
    'Missing required change: {changes}',
    'Missing required changes: {changes}',
    scalar @missing_requires,
    changes => join ' ', @missing_requires,
), 'Should have localized message missing dependencies';

is_deeply $engine->seen, [
    [check_conflicts => $change],
    [check_requires => $change],
], 'Should have called check_requires';
is_deeply +MockOutput->get_info, [
    ['  + ', $change->format_name]
], 'Should again have shown change name';
@missing_requires = ();

# Now make it die on the actual deploy.
$die = 'log_deploy_change';
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Shuld die on deploy failure';
is $@->message, 'AAAH!', 'Should be the underlying error';
is_deeply $engine->seen, [
    [check_conflicts => $change],
    [check_requires => $change],
    [run_file => $change->deploy_file],
    [log_fail_change => $change],
], 'It should failed to have been deployed';
is_deeply +MockOutput->get_info, [
    ['  + ', $change->format_name]
], 'Should have shown change name';

$die = '';

##############################################################################
# Test revert_change().
can_ok $engine, 'revert_change';
ok $engine->revert_change($change), 'Revert the change';
is_deeply $engine->seen, [
    [run_file => $change->revert_file],
    [log_revert_change => $change],
], 'It should have been reverted';
is_deeply +MockOutput->get_info, [
    ['  - ', $change->format_name]
], 'Should have shown reverted change name';

##############################################################################
# Test revert().
can_ok $engine, 'revert';
my $mock_sqitch = Test::MockModule->new('App::Sqitch');
$mock_sqitch->mock(plan => $plan);

# Start with no deployed IDs.
@deployed_change_ids = ();
throws_ok { $engine->revert } 'App::Sqitch::X',
    'Should get exception for no changes to revert';
is $@->ident, 'revert', 'Should be a revert exception';
is $@->message,  __ 'Nothing to revert (nothing deployed)',
    'Should have notified that there is nothing to revert';
is $@->exitval, 1, 'Exit val should be 1';
is_deeply $engine->seen, [
    [deployed_change_ids => undef],
], 'It should only have called deployed_change_ids()';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Try reverting to an unknown change.
throws_ok { $engine->revert('nonexistent') } 'App::Sqitch::X',
    'Revert should die on unknown change';
is $@->ident, 'revert', 'Should be another "revert" error';
is $@->message, __x(
    'Unknown revert target: "{target}"',
    target => 'nonexistent',
), 'The message should mention it is an unknown target';
is_deeply $engine->seen, [], 'No other methods should have been called';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Revert an undeployed target.
throws_ok { $engine->revert('@alpha') } 'App::Sqitch::X',
    'Revert should die on undeployed change';
is $@->ident, 'revert', 'Should be another "revert" error';
is $@->message, __x(
    'Target not deployed: "{target}"',
    target => '@alpha',
), 'The message should mention that the target is not deployed';
is_deeply $engine->seen, [
    [deployed_change_ids_since => $plan->get('@alpha')],
], 'Should have called deployed_change_ids_since';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Revert a change in the database, but not known in the plan.
@deployed_change_ids = ('this is not an id');
throws_ok { $engine->revert } 'App::Sqitch::X',
    'Revert should die on unknown change ID';
is $@->ident, 'revert', 'Should be yet another "revert" error';
is $@->message, __x(
    'Could not find change "{change}" ({id}) in the plan',
    change => 'bugaboo',
    id     => 'this is not an id',
), 'The message should mention the unknown ID';
is_deeply $engine->seen, [
    [deployed_change_ids => undef],
], 'Should have called deployed_change_ids_since';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting all changes from {destination}',
        destination => $engine->destination,
    )],
], 'Output should have said it was reverting all changes';

# Now revert from a deployed change.
@deployed_change_ids = map { $changes[$_]->id } (0..3);
ok $engine->revert, 'Revert all changes';
is_deeply $engine->seen, [
    [deployed_change_ids => undef],
    [run_file => $changes[3]->revert_file ],
    [log_revert_change => $changes[3] ],
    [run_file => $changes[2]->revert_file ],
    [log_revert_change => $changes[2] ],
    [run_file => $changes[1]->revert_file ],
    [log_revert_change => $changes[1] ],
    [run_file => $changes[0]->revert_file ],
    [log_revert_change => $changes[0] ],
], 'Should have reverted the changes in reverse order';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting all changes from {destination}',
        destination => $engine->destination,
    )],
    ['  - ', 'lolz'],
    ['  - ', 'widgets @beta'],
    ['  - ', 'users @alpha'],
    ['  - ', 'roles'],
], 'It should have said it was reverting all changes and listed them';

# Now just rever to an earlier change.
@deployed_change_ids = map { $changes[$_]->id } (2..3);
ok $engine->revert('@alpha'), 'Revert to @alpha';
is_deeply $engine->seen, [
    [deployed_change_ids_since => $changes[1]],
    [run_file => $changes[3]->revert_file ],
    [log_revert_change => $changes[3] ],
    [run_file => $changes[2]->revert_file ],
    [log_revert_change => $changes[2] ],
], 'Should have reverted only changes after @alpha';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting from {destination} to {target}',
        destination => $engine->destination,
        target      => '@alpha',
    )],
    ['  - ', 'lolz'],
    ['  - ', 'widgets @beta'],
], 'Output should show what it reverts to';

# Let it find it via the name.
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(get => sub {
    my ( $self, $name ) = @_;
    my $get = $mock_plan->original('get');
    return $self->$get('@alpha') if $name eq 'bugaboo';
    return $self->$get($name);
});
@deployed_change_ids = ('this is not an id');
ok $engine->revert, 'Revert by name rather than ID';
is_deeply $engine->seen, [
    [deployed_change_ids => undef],
    [run_file => $changes[1]->revert_file ],
    [log_revert_change => $changes[1] ],
], 'Should have reverted only @alpha';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting all changes from {destination}',
        destination => $engine->destination,
    )],
    ['  - ', 'users @alpha'],
], 'Output should show reverting all, though really only once, thanks to mocking';

$mock_plan->unmock_all;
