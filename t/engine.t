#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 599;
#use Test::More 'no_plan';
use App::Sqitch;
use App::Sqitch::Plan;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
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

can_ok $CLASS, qw(load new name no_prompt run_deploy run_revert run_verify uri);

my ($is_deployed_tag, $is_deployed_change) = (0, 0);
my @deployed_changes;
my @deployed_change_ids;
my @resolved;
my @requiring;
my @load_changes;
my $offset_change;
my $die = '';
my $record_work = 1;
my $updated_idx;
my ( $earliest_change_id, $latest_change_id, $initialized );
ENGINE: {
    # Stub out a engine.
    package App::Sqitch::Engine::whu;
    use Mouse;
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
    sub is_deployed_tag    { push @SEEN => [ is_deployed_tag   => $_[1] ]; $is_deployed_tag }
    sub is_deployed_change { push @SEEN => [ is_deployed_change  => $_[1] ]; $is_deployed_change }
    sub are_deployed_changes { shift; push @SEEN => [ are_deployed_changes  => [@_] ]; @deployed_change_ids }
    sub change_id_for      { shift; push @SEEN => [ change_id_for => {@_} ]; shift @resolved }
    sub change_offset_from_id { shift; push @SEEN => [ change_offset_from_id => [@_] ]; $offset_change }
    sub changes_requiring_change { push @SEEN => [ changes_requiring_change => $_[1] ]; @{ shift @requiring } }
    sub earliest_change_id { push @SEEN => [ earliest_change_id  => $_[1] ]; $earliest_change_id }
    sub latest_change_id   { push @SEEN => [ latest_change_id    => $_[1] ]; $latest_change_id }
    sub initialized        { push @SEEN => 'initialized'; $initialized }
    sub initialize         { push @SEEN => 'initialize' }
    sub register_project   { push @SEEN => 'register_project' }
    sub deployed_changes   { push @SEEN => [ deployed_changes => $_[1] ]; @deployed_changes }
    sub load_change        { push @SEEN => [ load_change => $_[1] ]; @load_changes }
    sub deployed_changes_since { push @SEEN => [ deployed_changes_since => $_[1] ]; @deployed_changes }
    sub mock_check_deploy  { shift; push @SEEN => [ check_deploy_dependencies => [@_] ] }
    sub mock_check_revert  { shift; push @SEEN => [ check_revert_dependencies => [@_] ] }
    sub begin_work         { push @SEEN => ['begin_work']  if $record_work }
    sub finish_work        { push @SEEN => ['finish_work'] if $record_work }
    sub _update_ids        { push @SEEN => ['_update_ids']; $updated_idx }
    sub log_new_tags       { push @SEEN => [ log_new_tags => $_[1] ]; $_[0] }

    sub seen { [@SEEN] }
    after seen => sub { @SEEN = () };

    sub name_for_change_id { return 'bugaboo' }
}

ok my $sqitch = App::Sqitch->new(
    _engine   => 'sqlite',
    db_name   => 'mydb',
    top_dir   => dir( qw(t sql) ),
    plan_file => file qw(t plans multi.plan)
), 'Load a sqitch sqitch object';

my $mock_engine = Test::MockModule->new($CLASS);

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
    is $@->message, 'Missing "uri" or "engine" parameter to load()',
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
throws_ok { $engine->name } 'App::Sqitch::X',
    'Should get error from base engine name';
is $@->ident, 'engine', 'Name error ident should be "engine"';
is $@->message, __('No engine specified; use --engine or set core.engine'),
    'Name error message should be correct';

ok $engine = App::Sqitch::Engine::whu->new({sqitch => $sqitch}),
    'Create a subclass name object';
is $engine->name, 'whu', 'Subclass oject name should be "whu"';
is +App::Sqitch::Engine::whu->name, 'whu', 'Subclass class name should be "whu"';

##############################################################################
# Test config_vars.
can_ok $CLASS, 'config_vars';
is_deeply [App::Sqitch::Engine->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'Should have database and client in engine base class';

##############################################################################
# Test variables.
can_ok $CLASS, qw(variables set_variables clear_variables);
is_deeply [$engine->variables], [], 'Should have no variables';
ok $engine->set_variables(foo => 'bar'), 'Add a variable';
is_deeply [$engine->variables], [foo => 'bar'], 'Should have the variable';
ok $engine->set_variables(foo => 'baz', whu => 'hi', yo => 'stellar'),
    'Set more variables';
is_deeply {$engine->variables}, {foo => 'baz', whu => 'hi', yo => 'stellar'},
    'Should have all of the variables';
$engine->clear_variables;
is_deeply [$engine->variables], [], 'Should again have no variables';

##############################################################################
# Test target.
ok $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
    target => 'foo',
}), 'Load engine';
is $engine->target, 'foo', 'Target should be as passed';

ok $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
}), 'Load engine';
is $engine->target, 'db:whu:mydb', 'Target should be URI string';

# Make sure password is removed from the target.
ok $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
    uri => URI->new('db:whu://foo:bar@localhost/blah'),
}), 'Load engine with URI with password';
is $engine->target, $engine->uri->as_string,
    'Target should be the URI stringified';

# Try a target in the configuration.
MOCKCONFIG: {
    local $ENV{SQITCH_CONFIG} = file qw(t local.conf);
    ok my $engine = $CLASS->load({
        sqitch => App::Sqitch->new( _engine => 'sqlite' ),
        engine => 'sqlite',
    }), 'Load engine';
    is $engine->target, 'devdb', 'Target should be read from config';

    ok $engine = $CLASS->load({
        sqitch => App::Sqitch->new( _engine => 'sqlite' ),
        engine => 'sqlite',
        uri    => URI->new('db:sqlite:/var/db/widgets.db'),
    }), 'Load engine with URI';
    is $engine->target, 'devdb', 'Target should still be "devdb"';
}

##############################################################################
# Test destination.
ok $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
}), 'Load engine';
is $engine->destination, 'db:whu:mydb', 'Destination should be URI string';
is $engine->registry_destination, $engine->destination,
    'Rgistry destination should be the same as destination';

# Make sure password is removed from the destination.
ok $engine = $CLASS->load({
    sqitch => $sqitch,
    engine => 'whu',
    uri => URI->new('db:whu://foo:bar@localhost/blah'),
}), 'Load engine with URI with password';
like $engine->destination, qr{^db:whu://foo:?\@localhost/mydb$},
    'Destination should not include password';
is $engine->registry_destination, $engine->destination,
    'Meta destination should again be the same as destination';

##############################################################################
# Test abstract methods.
ok $engine = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object again";
for my $abs (qw(
    initialized
    initialize
    register_project
    run_file
    run_handle
    log_deploy_change
    log_fail_change
    log_revert_change
    log_new_tags
    is_deployed_tag
    is_deployed_change
    are_deployed_changes
    change_id_for
    changes_requiring_change
    earliest_change_id
    latest_change_id
    deployed_changes
    deployed_changes_since
    load_change
    name_for_change_id
    current_state
    current_changes
    current_tags
    search_events
    registered_projects
    change_offset_from_id
)) {
    throws_ok { $engine->$abs } qr/\Q$CLASS has not implemented $abs()/,
        "Should get an unimplemented exception from $abs()"
}

##############################################################################
# Test _load_changes().
can_ok $engine, '_load_changes';
my $now = App::Sqitch::DateTime->now;
my $plan = $sqitch->plan;

# Mock App::Sqitch::DateTime so that dbchange tags all have the same
# timestamps.
my $mock_dt = Test::MockModule->new('App::Sqitch::DateTime');
$mock_dt->mock(now => $now);


for my $spec (
    [ 'no change' => [] ],
    [ 'undef' => [undef] ],
    ['no tags' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
    ]],
    ['multiple hashes with no tags' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
        {
            id            => 'ae5b4397f78dfc6072ccf6d505b17f9624d0e3b0',
            name          => 'booyah',
            project       => 'engine',
            note          => 'Whatever',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
    ]],
    ['tags' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(foo bar)],
        },
    ]],
    ['tags with leading @' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(@foo @bar)],
        },
    ]],
    ['multiple hashes with tags' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(foo bar)],
        },
        {
            id            => 'ae5b4397f78dfc6072ccf6d505b17f9624d0e3b0',
            name          => 'booyah',
            project       => 'engine',
            note          => 'Whatever',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(@foo @bar)],
        },
    ]],
    ['reworked change' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(foo bar)],
        },
        {
            id            => 'df18b5c9739772b210fcf2c4edae095e2f6a4163',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            rtags         => [qw(howdy)],
        },
    ]],
    ['reworked change & multiple tags' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(foo bar)],
        },
        {
            id            => 'ae5b4397f78dfc6072ccf6d505b17f9624d0e3b0',
            name          => 'booyah',
            project       => 'engine',
            note          => 'Whatever',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(@settle)],
        },
        {
            id            => 'df18b5c9739772b210fcf2c4edae095e2f6a4163',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            rtags         => [qw(booyah howdy)],
        },
    ]],
    ['doubly reworked change' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            tags          => [qw(foo bar)],
        },
        {
            id            => 'df18b5c9739772b210fcf2c4edae095e2f6a4163',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            rtags         => [qw(howdy)],
            tags          => [qw(why)],
        },
        {
            id            => 'f38ceb6efcf2a813104b7bb08cc90667033ddf6b',
            name          => 'howdy',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
            rtags         => [qw(howdy)],
        },
    ]],
) {
    my ($desc, $args) = @{ $spec };
    my %seen;
    is_deeply [ $engine->_load_changes(@{ $args }) ], [ map {
        my $tags  = $_->{tags}  || [];
        my $rtags = $_->{rtags};
        my $c = App::Sqitch::Plan::Change->new(%{ $_ }, plan => $plan );
        $c->add_tag(App::Sqitch::Plan::Tag->new(
            name      => $_,
            plan      => $plan,
            change    => $c,
            timestamp => $now,
        )) for map { s/^@//; $_ } @{ $tags };
        if (my $dupe = $seen{ $_->{name} }) {
            $dupe->add_rework_tags( map { $seen{$_}->tags } @{ $rtags });
        }
        $seen{ $_->{name} } = $c;
        $c;
    } grep { $_ } @{ $args }], "Should load changes with $desc";
}

# Rework a change in the plan.
my $you = $plan->get('you');
my $this_rocks = $plan->get('this/rocks');
my $hey_there = $plan->get('hey-there');
ok my $rev_change = $plan->rework( name => 'you' ), 'Rework change "you"';
ok $plan->tag( name => '@beta1' ), 'Tag @beta1';

# Load changes
for my $spec (
    [ 'Unplanned change' => [
        {
            id            => 'c8a60f1a4fdab2cf91ee7f6da08f4ac52a732b4d',
            name          => 'you',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
        {
            id            => 'df18b5c9739772b210fcf2c4edae095e2f6a4163',
            name          => 'this/rocks',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
    ]],
    [ 'reworked change without reworked version deployed' => [
        {
            id            => $you->id,
            name          => $you->name,
            project       => $you->project,
            note          => $you->note,
            planner_name  => $you->planner_name,
            planner_email => $you->planner_email,
            timestamp     => $you->timestamp,
            ptags         => [ $hey_there->tags, $you->tags ],
        },
        {
            id            => $this_rocks->id,
            name          => 'this/rocks',
            project       => 'engine',
            note          => 'For realz',
            planner_name  => 'Barack Obama',
            planner_email => 'bo@whitehouse.gov',
            timestamp     => $now,
        },
    ]],
    [ 'reworked change with reworked version deployed' => [
        {
            id            => $you->id,
            name          => $you->name,
            project       => $you->project,
            note          => $you->note,
            planner_name  => $you->planner_name,
            planner_email => $you->planner_email,
            timestamp     => $you->timestamp,
            tags          => [qw(@foo @bar)],
            ptags         => [ $hey_there->tags, $you->tags ],
        },
        {
            id            => $rev_change->id,
            name          => $rev_change->name,
            project       => 'engine',
            note          => $rev_change->note,
            planner_name  => $rev_change->planner_name,
            planner_email => $rev_change->planner_email,
            timestamp     => $rev_change->timestamp,
        },
    ]],
) {
    my ($desc, $args) = @{ $spec };
    my %seen;
    is_deeply [ $engine->_load_changes(@{ $args }) ], [ map {
        my $tags  = $_->{tags}  || [];
        my $rtags = $_->{rtags};
        my $ptags = $_->{ptags};
        my $c = App::Sqitch::Plan::Change->new(%{ $_ }, plan => $plan );
        $c->add_tag(App::Sqitch::Plan::Tag->new(
            name      => $_,
            plan      => $plan,
            change    => $c,
            timestamp => $now,
        )) for map { s/^@//; $_ } @{ $tags };
        my %seen_tags;
        if (@{ $ptags || [] }) {
            $c->add_rework_tags( @{ $ptags });
        }
        if (my $dupe = $seen{ $_->{name} }) {
            $dupe->add_rework_tags( map { $seen{$_}->tags } @{ $rtags });
        }
        $seen{ $_->{name} } = $c;
        $c;
    } grep { $_ } @{ $args }], "Should load changes with $desc";
}

# diag $_->format_name_with_tags for $plan->changes;
# diag $_->id for $plan->changes;

##############################################################################
# Test deploy_change and revert_change.
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Create a subclass name object again';
can_ok $engine, 'deploy_change', 'revert_change';

my $change = App::Sqitch::Plan::Change->new( name => 'users', plan => $sqitch->plan );

ok $engine->deploy_change($change), 'Deploy a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->deploy_file ],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'deploy_change should have called the proper methods';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the deployment';
is_deeply +MockOutput->get_info, [[__ 'ok' ]],
    'Output should reflect success';

# Have it log only.
$engine->log_only(1);
ok $engine->deploy_change($change), 'Only log a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'log-only deploy_change should not have called run_file';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the logging';
is_deeply +MockOutput->get_info, [[__ 'ok' ]],
    'Output should reflect deploy success';

# Have it verify.
ok $engine->with_verify(1), 'Enable verification';
$engine->log_only(0);
ok $engine->deploy_change($change), 'Deploy a change to be verified';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->deploy_file ],
    [run_file => $change->verify_file ],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'deploy_change with verification should run the verify file';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the logging';
is_deeply +MockOutput->get_info, [[__ 'ok' ]],
    'Output should reflect deploy success';

# Have it verify *and* log-only.
ok $engine->log_only(1), 'Enable log_only';
ok $engine->deploy_change($change), 'Verify and log a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->verify_file ],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'deploy_change with verification and log-only should not run deploy';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the logging';
is_deeply +MockOutput->get_info, [[__ 'ok' ]],
    'Output should reflect deploy success';

# Make it fail.
$die = 'run_file';
$engine->log_only(0);
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Deploy change with error';
is $@->message, 'AAAH!', 'Error should be from run_file';
is_deeply $engine->seen, [
    ['begin_work'],
    [log_fail_change => $change ],
    ['finish_work'],
], 'Should have logged change failure';
$die = '';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the deployment, even with failure';
is_deeply +MockOutput->get_info, [[__ 'not ok' ]],
    'Output should reflect deploy failure';

# Make the verify fail.
$mock_engine->mock( verify_change => sub { hurl 'WTF!' });
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Deploy change with failed verification';
is $@->message, __ 'Deploy failed', 'Error should be from deploy_change';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->deploy_file ],
    ['begin_work'],
    [run_file => $change->revert_file ],
    [log_fail_change => $change ],
    ['finish_work'],
], 'Should have logged verify failure';
$die = '';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the deployment, even with verify failure';
is_deeply +MockOutput->get_info, [[__ 'not ok' ]],
    'Output should reflect deploy failure';
is_deeply +MockOutput->get_vent, [['WTF!']],
    'Verify error should have been vented';

# Make the verify fail with log only.
ok $engine->log_only(1), 'Enable log_only';
throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
    'Deploy change with log-only and failed verification';
is $@->message, __ 'Deploy failed', 'Error should be from deploy_change';
is_deeply $engine->seen, [
    ['begin_work'],
    ['begin_work'],
    [log_fail_change => $change ],
    ['finish_work'],
], 'Should have logged verify failure but not reverted';
$die = '';
is_deeply +MockOutput->get_info_literal, [[
    '  + users ..', '' , ' '
]], 'Output should reflect the deployment, even with verify failure';
is_deeply +MockOutput->get_info, [[__ 'not ok' ]],
    'Output should reflect deploy failure';
is_deeply +MockOutput->get_vent, [['WTF!']],
    'Verify error should have been vented';

# Try a change with no verify file.
$engine->log_only(0);
$mock_engine->unmock( 'verify_change' );
$change = App::Sqitch::Plan::Change->new( name => 'foo', plan => $sqitch->plan );
ok $engine->deploy_change($change), 'Deploy a change with no verify script';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->deploy_file ],
    [log_deploy_change => $change ],
    ['finish_work'],
], 'deploy_change with no verify file should not run it';
is_deeply +MockOutput->get_info_literal, [[
    '  + foo ..', '' , ' '
]], 'Output should reflect the logging';
is_deeply +MockOutput->get_info, [[__ 'ok' ]],
    'Output should reflect deploy success';
is_deeply +MockOutput->get_vent, [
    [__x 'Verify script {file} does not exist', file => $change->verify_file],
], 'A warning about no verify file should have been emitted';

# Alright, disable verify now.
$engine->with_verify(0);

ok $engine->revert_change($change), 'Revert a change';
is_deeply $engine->seen, [
    ['begin_work'],
    [run_file => $change->revert_file ],
    [log_revert_change => $change ],
    ['finish_work'],
], 'revert_change should have called the proper methods';
is_deeply +MockOutput->get_info_literal, [[
    '  - foo ..', '', ' '
]], 'Output should reflect reversion';
is_deeply +MockOutput->get_info, [[__ 'ok']],
    'Output should acknowldge revert success';

# Revert with log-only.
ok $engine->log_only(1), 'Enable log_only';
ok $engine->revert_change($change), 'Revert a change with log-only';
is_deeply $engine->seen, [
    ['begin_work'],
    [log_revert_change => $change ],
    ['finish_work'],
], 'Log-only revert_change should not have run the change script';
is_deeply +MockOutput->get_info_literal, [[
    '  - foo ..', '', ' '
]], 'Output should reflect logged reversion';
is_deeply +MockOutput->get_info, [[__ 'ok']],
    'Output should acknowldge revert success';
$record_work = 0;

##############################################################################
# Test earliest_change() and latest_change().
chdir 't';
my $plan_file = file qw(sql sqitch.plan);
my $sqitch_old = $sqitch; # Hang on to this because $change does not retain it.
$sqitch = App::Sqitch->new( _engine => 'sqlite', plan_file => $plan_file, top_dir => dir 'sql' );
ok $engine = App::Sqitch::Engine::whu->new( sqitch => $sqitch ),
    'Engine with sqitch with plan file';
$plan = $sqitch->plan;
my @changes = $plan->changes;

$latest_change_id = $changes[0]->id;
is $engine->latest_change, $changes[0], 'Should get proper change from latest_change()';
is_deeply $engine->seen, [[ latest_change_id => undef ]],
    'Latest change ID should have been called with no arg';
$latest_change_id = $changes[2]->id;
is $engine->latest_change(2), $changes[2],
    'Should again get proper change from latest_change()';
is_deeply $engine->seen, [[ latest_change_id => 2 ]],
    'Latest change ID should have been called with offset arg';
$latest_change_id = undef;

$earliest_change_id = $changes[0]->id;
is $engine->earliest_change, $changes[0], 'Should get proper change from earliest_change()';
is_deeply $engine->seen, [[ earliest_change_id => undef ]],
    'Earliest change ID should have been called with no arg';
$earliest_change_id = $changes[2]->id;
is $engine->earliest_change(4), $changes[2],
    'Should again get proper change from earliest_change()';
is_deeply $engine->seen, [[ earliest_change_id => 4 ]],
    'Earliest change ID should have been called with offset arg';
$earliest_change_id = undef;

##############################################################################
# Test _sync_plan()
can_ok $CLASS, '_sync_plan';
$engine->seen;

is $plan->position, -1, 'Plan should start at position -1';
is $engine->start_at, undef, 'start_at should be undef';

ok $engine->_sync_plan, 'Sync the plan';
is $plan->position, -1, 'Plan should still be at position -1';
is $engine->start_at, undef, 'start_at should still be undef';
$plan->position(4);
is_deeply $engine->seen, [['latest_change_id', undef]],
    'Should not have updated IDs';

ok $engine->_sync_plan, 'Sync the plan again';
is $plan->position, -1, 'Plan should again be at position -1';
is $engine->start_at, undef, 'start_at should again be undef';
is_deeply $engine->seen, [['latest_change_id', undef]],
    'Still should not have updated IDs';

# Have latest_item return a tag.
$latest_change_id = $changes[1]->old_id;
$updated_idx = 2;
ok $engine->_sync_plan, 'Sync the plan to a tag';
is $plan->position, 2, 'Plan should now be at position 1';
is $engine->start_at, 'widgets@beta', 'start_at should now be widgets@beta';
is_deeply $engine->seen, [
    ['latest_change_id', undef],
    ['_update_ids'],
    ['log_new_tags' => $plan->change_at(2)],
], 'Should have updated IDs';

##############################################################################
# Test deploy.
can_ok $CLASS, 'deploy';
$latest_change_id = undef;
$plan->reset;
$engine->seen;
@changes = $plan->changes;

# Mock the deploy methods to log which were called.
my $deploy_meth;
for my $meth (qw(_deploy_all _deploy_by_tag _deploy_by_change)) {
    my $orig = $CLASS->can($meth);
    $mock_engine->mock($meth => sub {
        $deploy_meth = $meth;
        $orig->(@_);
    });
}

# Mock dependency checking to add its call to the seen stuff.
$mock_engine->mock( check_deploy_dependencies => sub {
    shift->mock_check_deploy(@_);
});
$mock_engine->mock( check_revert_dependencies => sub {
    shift->mock_check_revert(@_);
});

ok $engine->deploy('@alpha'), 'Deploy to @alpha';
is $plan->position, 1, 'Plan should be at position 1';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
    'initialize',
    'register_project',
    [check_deploy_dependencies => [$plan, 1]],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should have deployed through @alpha';

is $deploy_meth, '_deploy_all', 'Should have called _deploy_all()';
is_deeply +MockOutput->get_info, [
    [__x 'Adding registry tables to {destination}',
        destination => $engine->registry_destination,
    ],
    [__x 'Deploying changes through {change} to {destination}',
        destination =>  $engine->destination,
        change      => $plan->get('@alpha')->format_name_with_tags,
    ],
    [__ 'ok'],
    [__ 'ok'],
], 'Should have seen the output of the deploy to @alpha';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '.......', ' '],
    ['  + users @alpha ..', '', ' '],
], 'Both change names should be output';

# Try with log-only in all modes.
for my $mode (qw(change tag all)) {
    ok $engine->log_only(1), 'Enable log_only';
    ok $engine->deploy('@alpha', $mode, 1), 'Log-only deploy in $mode mode to @alpha';
    is $plan->position, 1, 'Plan should be at position 1';
    is_deeply $engine->seen, [
        [latest_change_id => undef],
        'initialized',
        'initialize',
        'register_project',
        [check_deploy_dependencies => [$plan, 1]],
        [log_deploy_change => $changes[0]],
        [log_deploy_change => $changes[1]],
    ], 'Should have deployed through @alpha without running files';

    my $meth = $mode eq 'all' ? 'all' : ('by_' . $mode);
    is $deploy_meth, "_deploy_$meth", "Should have called _deploy_$meth()";
    is_deeply +MockOutput->get_info, [
        [
            __x 'Adding registry tables to {destination}',
            destination => $engine->registry_destination,
        ],
        [
            __x 'Deploying changes through {change} to {destination}',
            destination =>  $engine->destination,
            change      => $plan->get('@alpha')->format_name_with_tags,
        ],
        [__ 'ok'],
        [__ 'ok'],
    ], 'Should have seen the output of the deploy to @alpha';
    is_deeply +MockOutput->get_info_literal, [
        ['  + roles ..', '.......', ' '],
        ['  + users @alpha ..', '', ' '],
    ], 'Both change names should be output';
}

# Try with no need to initialize.
$initialized = 1;
$plan->reset;
$engine->log_only(0);
ok $engine->deploy('@alpha', 'tag'), 'Deploy to @alpha with tag mode';
is $plan->position, 1, 'Plan should again be at position 1';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
    'register_project',
    [check_deploy_dependencies => [$plan, 1]],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should have deployed through @alpha without initialization';

is $deploy_meth, '_deploy_by_tag', 'Should have called _deploy_by_tag()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying changes through {change} to {destination}',
        destination =>  $engine->registry_destination,
        change      => $plan->get('@alpha')->format_name_with_tags,
    ],
    [__ 'ok'],
    [__ 'ok'],
], 'Should have seen the output of the deploy to @alpha';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '.......', ' '],
    ['  + users @alpha ..', '', ' '],
], 'Both change names should be output';

# Try a bogus change.
throws_ok { $engine->deploy('nonexistent') } 'App::Sqitch::X',
    'Should get an error for an unknown change';
is $@->message, __x(
    'Unknown change: "{change}"',
    change => 'nonexistent',
), 'The exception should report the unknown change';
is_deeply $engine->seen, [
    [latest_change_id => undef],
], 'Only latest_item() should have been called';

# Start with @alpha.
$latest_change_id = ($changes[1]->tags)[0]->id;
ok $engine->deploy('@alpha'), 'Deploy to alpha thrice';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    ['log_new_tags' => $changes[1]],
], 'Only latest_item() should have been called';
is_deeply +MockOutput->get_info, [
    [__x 'Nothing to deploy (already at "{change}"', change => '@alpha'],
], 'Should notify user that already at @alpha';

# Start with widgets.
$latest_change_id = $changes[2]->id;
throws_ok { $engine->deploy('@alpha') } 'App::Sqitch::X',
    'Should fail changeing older change';
is $@->ident, 'deploy', 'Should be a "deploy" error';
is $@->message,  __ 'Cannot deploy to an earlier change; use "revert" instead',
    'It should suggest using "revert"';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    ['log_new_tags' => $changes[2]],
], 'Should have called latest_item() and latest_tag()';

# Make sure we can deploy everything by change.
$latest_change_id = undef;
$plan->reset;
$plan->add( name => 'lolz', note => 'ha ha' );
@changes = $plan->changes;
ok $engine->deploy(undef, 'change'), 'Deploy everything by change';
is $plan->position, 3, 'Plan should be at position 3';
is_deeply $engine->seen, [
    [latest_change_id => undef],
    'initialized',
    'register_project',
    [check_deploy_dependencies => [$plan, 3]],
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should have deployed everything';

is $deploy_meth, '_deploy_by_change', 'Should have called _deploy_by_change()';
is_deeply +MockOutput->get_info, [
    [__x 'Deploying changes to {destination}', destination =>  $engine->destination ],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
], 'Should have emitted deploy announcement and successes';

is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '........', ' '],
    ['  + users @alpha ..', '.', ' '],
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '.........', ' '],
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
    'register_project',
    [check_deploy_dependencies => [$plan, 3]],
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
    my $sqitch = App::Sqitch->new( _engine => 'sqlite', plan_file => $plan_file );
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
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should changewise deploy to index 2';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
], 'Should have seen output of each change';
is_deeply +MockOutput->get_info, [[__ 'ok' ], [__ 'ok']],
    'Output should reflect deploy successes';

ok $engine->_deploy_by_change($plan, 3), 'Deploy changewise to index 2';
is_deeply $engine->seen, [
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should changewise deploy to from index 2 to index 3';
is_deeply +MockOutput->get_info_literal, [
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '', ' '],
], 'Should have seen output of changes 2-3';
is_deeply +MockOutput->get_info, [[__ 'ok' ], [__ 'ok']],
    'Output should reflect deploy successes';

# Make it die.
$plan->reset;
$die = 'run_file';
throws_ok { $engine->_deploy_by_change($plan, 2) } 'App::Sqitch::X',
    'Die in _deploy_by_change';
is $@->message, 'AAAH!', 'It should have died in run_file';
is_deeply $engine->seen, [
    [log_fail_change => $changes[0] ],
], 'It should have logged the failure';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
], 'Should have seen output for first change';
is_deeply +MockOutput->get_info, [[__ 'not ok']],
    'Output should reflect deploy failure';
$die = '';

##############################################################################
# Test _deploy_by_tag().
$plan->reset;
$mock_engine->unmock('_deploy_by_tag');
ok $engine->_deploy_by_tag($plan, 1), 'Deploy tagwise to index 1';

is_deeply $engine->seen, [
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
], 'Should have seen output of each change';
is_deeply +MockOutput->get_info, [[__ 'ok' ], [__ 'ok']],
    'Output should reflect deploy successes';

ok $engine->_deploy_by_tag($plan, 3), 'Deploy tagwise to index 3';
is_deeply $engine->seen, [
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
    [run_file => $changes[3]->deploy_file],
    [log_deploy_change => $changes[3]],
], 'Should tagwise deploy from index 2 to index 3';
is_deeply +MockOutput->get_info_literal, [
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '', ' '],
], 'Should have seen output of changes 3-3';
is_deeply +MockOutput->get_info, [[__ 'ok' ], [__ 'ok']],
    'Output should reflect deploy successes';

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
    [run_file => $changes[2]->deploy_file],
    [run_file => $changes[3]->deploy_file],
    [run_file => $changes[4]->deploy_file],
    [run_file => $changes[5]->deploy_file],
    [run_file => $changes[5]->revert_file],
    [log_fail_change => $changes[5] ],
    [run_file => $changes[4]->revert_file],
    [log_revert_change => $changes[4]],
    [run_file => $changes[3]->revert_file],
    [log_revert_change => $changes[3]],
], 'It should have reverted back to the last deployed tag';

is_deeply +MockOutput->get_info_literal, [
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '', ' '],
    ['  + tacos ..', '', ' '],
    ['  + curry ..', '', ' '],
    ['  - tacos ..', '', ' '],
    ['  - lolz ..', '', ' '],
], 'Should have seen deploy and revert messages (excluding curry revert)';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failure';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {change}', change => 'widgets @beta']
], 'The original error should have been vented';
$mock_whu->unmock('log_deploy_change');

# Make it die with log-only..
$plan->position(1);
ok $engine->log_only(1), 'Enable log_only';
$mock_whu->mock(log_deploy_change => sub { hurl 'ROFL' if $_[1] eq $changes[-1] });
throws_ok { $engine->_deploy_by_tag($plan, $#changes, 1) } 'App::Sqitch::X',
    'Die in log_deploy_change log-only';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
is_deeply $engine->seen, [
    [log_fail_change => $changes[5] ],
    [log_revert_change => $changes[4]],
    [log_revert_change => $changes[3]],
], 'It should have run no deploy or revert scripts';

is_deeply +MockOutput->get_info_literal, [
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '', ' '],
    ['  + tacos ..', '', ' '],
    ['  + curry ..', '', ' '],
    ['  - tacos ..', '', ' '],
    ['  - lolz ..', '', ' '],
], 'Should have seen deploy and revert messages (excluding curry revert)';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failure';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {change}', change => 'widgets @beta']
], 'The original error should have been vented';
$mock_whu->unmock('log_deploy_change');

# Now have it fail back to the beginning.
$plan->reset;
$engine->log_only(0);
$mock_whu->mock(run_file => sub { die 'ROFL' if $_[1]->basename eq 'users.sql' });
throws_ok { $engine->_deploy_by_tag($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_by_tag again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [log_deploy_change => $changes[0]],
    [log_fail_change => $changes[1]],
    [log_revert_change => $changes[0]],
], 'Should have logged back to the beginning';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  - roles ..', '', ' '],
], 'Should have seen deploy and revert messages';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failure';
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
    [log_deploy_change => $changes[0]],
    [log_deploy_change => $changes[1]],
    [log_deploy_change => $changes[2]],
    [log_deploy_change => $changes[3]],
    [log_deploy_change => $changes[4]],
    [log_deploy_change => $changes[5]],
    [log_fail_change => $changes[6]],
    [log_revert_change => $changes[5] ],
    [log_revert_change => $changes[4] ],
    [log_revert_change => $changes[3] ],
], 'Should have reverted back to last tag';

is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  + widgets @beta ..', '', ' '],
    ['  + lolz ..', '', ' '],
    ['  + tacos ..', '', ' '],
    ['  + curry ..', '', ' '],
    ['  + dr_evil ..', '', ' '],
    ['  - curry ..', '', ' '],
    ['  - tacos ..', '', ' '],
    ['  - lolz ..', '', ' '],
], 'Should have user change reversion messages';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failure';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {change}', change => 'widgets @beta']
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
    [log_deploy_change => $changes[0] ],
    [log_fail_change => $changes[1] ],
], 'Should have tried to revert one change';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  - roles ..', '', ' '],
], 'Should have seen revert message';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'not ok' ],
], 'Output should reflect deploy successes and failure';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {change}', change => 'whatever'],
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
    [run_file => $changes[0]->deploy_file],
    [log_deploy_change => $changes[0]],
    [run_file => $changes[1]->deploy_file],
    [log_deploy_change => $changes[1]],
], 'Should tagwise deploy to index 1';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
], 'Should have seen output of each change';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes';

ok $engine->_deploy_all($plan, 2), 'Deploy tagwise to index 2';
is_deeply $engine->seen, [
    [run_file => $changes[2]->deploy_file],
    [log_deploy_change => $changes[2]],
], 'Should tagwise deploy to from index 1 to index 2';
is_deeply +MockOutput->get_info_literal, [
    ['  + widgets @beta ..', '', ' '],
], 'Should have seen output of changes 3-4';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
], 'Output should reflect deploy successe';

# Make it die.
$plan->reset;
$mock_whu->mock(log_deploy_change => sub { hurl 'ROFL' if $_[1] eq $changes[2] });
throws_ok { $engine->_deploy_all($plan, 3) } 'App::Sqitch::X',
    'Die in _deploy_all';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
$mock_whu->unmock('log_deploy_change');
is_deeply $engine->seen, [
    [run_file => $changes[0]->deploy_file],
    [run_file => $changes[1]->deploy_file],
    [run_file => $changes[2]->deploy_file],
    [run_file => $changes[2]->revert_file],
    [log_fail_change => $changes[2]],
    [run_file => $changes[1]->revert_file],
    [log_revert_change => $changes[1]],
    [run_file => $changes[0]->revert_file],
    [log_revert_change => $changes[0]],
], 'It should have logged up to the failure';

is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  + widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '', ' '],
    ['  - roles ..', '', ' '],
], 'Should have seen deploy and revert messages excluding revert for failed logging';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failures';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting all changes'],
], 'The original error should have been vented';
$die = '';

# Make it die with log-only.
$plan->reset;
ok $engine->log_only(1), 'Enable log_only';
$mock_whu->mock(log_deploy_change => sub { hurl 'ROFL' if $_[1] eq $changes[2] });
throws_ok { $engine->_deploy_all($plan, 3, 1) } 'App::Sqitch::X',
    'Die in log-only _deploy_all';
is $@->message, __('Deploy failed'), 'Should get final deploy failure message';
$mock_whu->unmock('log_deploy_change');
is_deeply $engine->seen, [
    [log_fail_change => $changes[2]],
    [log_revert_change => $changes[1]],
    [log_revert_change => $changes[0]],
], 'It should have run no deploys or reverts';

is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  + widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '', ' '],
    ['  - roles ..', '', ' '],
], 'Should have seen deploy and revert messages excluding revert for failed logging';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failures';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__ 'Reverting all changes'],
], 'The original error should have been vented';
$die = '';

# Now have it fail on a later change, should still go all the way back.
$plan->reset;
$engine->log_only(0);
$mock_whu->mock(run_file => sub { hurl 'ROFL' if $_[1]->basename eq 'widgets.sql' });
throws_ok { $engine->_deploy_all($plan, $plan->count -1 ) } 'App::Sqitch::X',
    'Die in _deploy_all again';
is $@->message, __('Deploy failed'), 'Should again get final deploy failure message';
is_deeply $engine->seen, [
    [log_deploy_change => $changes[0]],
    [log_deploy_change => $changes[1]],
    [log_fail_change => $changes[2]],
    [log_revert_change => $changes[1]],
    [log_revert_change => $changes[0]],
], 'Should have reveted all changes and tags';
is_deeply +MockOutput->get_info_literal, [
    ['  + roles ..', '', ' '],
    ['  + users @alpha ..', '', ' '],
    ['  + widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '', ' '],
    ['  - roles ..', '', ' '],
], 'Should see all changes revert';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failures';
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
    [log_deploy_change => $changes[3]],
    [log_deploy_change => $changes[4]],
    [log_deploy_change => $changes[5]],
    [log_fail_change => $changes[6]],
    [log_revert_change => $changes[5]],
    [log_revert_change => $changes[4]],
    [log_revert_change => $changes[3]],
], 'Should have deployed to dr_evil and revered down to @alpha';

is_deeply +MockOutput->get_info_literal, [
    ['  + lolz ..', '', ' '],
    ['  + tacos ..', '', ' '],
    ['  + curry ..', '', ' '],
    ['  + dr_evil ..', '', ' '],
    ['  - curry ..', '', ' '],
    ['  - tacos ..', '', ' '],
    ['  - lolz ..', '', ' '],
], 'Should see changes revert back to @alpha';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'not ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
    [__ 'ok' ],
], 'Output should reflect deploy successes and failures';
is_deeply +MockOutput->get_vent, [
    ['ROFL'],
    [__x 'Reverting to {change}', change => '@alpha'],
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
    [run_file => $change->deploy_file],
    [log_deploy_change => $change],
], 'It should have been deployed';
is_deeply +MockOutput->get_info_literal, [
    ['  + foo ..', '', ' ']
], 'Should have shown change name';
is_deeply +MockOutput->get_info, [
    [__ 'ok' ],
], 'Output should reflect deploy success';

my $make_deps = sub {
    my $conflicts = shift;
    return map {
        my $dep = App::Sqitch::Plan::Depend->new(
            change    => $_,
            plan      => $plan,
            project   => $plan->project,
            conflicts => $conflicts,
        );
        $dep;
    } @_;
};

DEPLOYDIE: {
    my $mock_depend = Test::MockModule->new('App::Sqitch::Plan::Depend');
    $mock_depend->mock(id => sub { undef });

    # Now make it die on the actual deploy.
    $die = 'log_deploy_change';
    my @requires  = $make_deps->( 0, qw(foo bar) );
    my @conflicts = $make_deps->( 1, qw(dr_evil) );
    my $change    = App::Sqitch::Plan::Change->new(
        name      => 'foo',
        plan      => $sqitch->plan,
        requires  => \@requires,
        conflicts => \@conflicts,
    );
    throws_ok { $engine->deploy_change($change) } 'App::Sqitch::X',
        'Shuld die on deploy failure';
    is $@->message, __ 'Deploy failed', 'Should be told the deploy failed';
    is_deeply $engine->seen, [
        [run_file => $change->deploy_file],
        [run_file => $change->revert_file],
        [log_fail_change => $change],
    ], 'It should failed to have been deployed';
    is_deeply +MockOutput->get_vent, [
        ['AAAH!'],
    ], 'Should have vented the original error';
    is_deeply +MockOutput->get_info_literal, [
        ['  + foo ..', '', ' '],
    ], 'Should have shown change name';
        is_deeply +MockOutput->get_info, [
            [__ 'not ok' ],
        ], 'Output should reflect deploy failure';
    $die = '';
}

##############################################################################
# Test revert_change().
can_ok $engine, 'revert_change';
ok $engine->revert_change($change), 'Revert the change';
is_deeply $engine->seen, [
    [run_file => $change->revert_file],
    [log_revert_change => $change],
], 'It should have been reverted';
is_deeply +MockOutput->get_info_literal, [
    ['  - foo ..', '', ' ']
], 'Should have shown reverted change name';
is_deeply +MockOutput->get_info, [
    [__ 'ok'],
], 'And the revert failure should be "ok"';

##############################################################################
# Test revert().
can_ok $engine, 'revert';
$mock_engine->mock(plan => $plan);

# Start with no deployed IDs.
@deployed_changes = ();
throws_ok { $engine->revert } 'App::Sqitch::X',
    'Should get exception for no changes to revert';
is $@->ident, 'revert', 'Should be a revert exception';
is $@->message,  __ 'Nothing to revert (nothing deployed)',
    'Should have notified that there is nothing to revert';
is $@->exitval, 1, 'Exit val should be 1';
is_deeply $engine->seen, [
    [deployed_changes => undef],
], 'It should only have called deployed_changes()';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Try reverting to an unknown change.
throws_ok { $engine->revert('nonexistent') } 'App::Sqitch::X',
    'Revert should die on unknown change';
is $@->ident, 'revert', 'Should be another "revert" error';
is $@->message, __x(
    'Unknown change: "{change}"',
    change => 'nonexistent',
), 'The message should mention it is an unknown change';
is_deeply $engine->seen, [['change_id_for', {
    change_id => undef,
    change  => 'nonexistent',
    tag     => undef,
    project => 'sql',
}]], 'Should have called change_id_for() with change name';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Try reverting to an unknown change ID.
throws_ok { $engine->revert('8d77c5f588b60bc0f2efcda6369df5cb0177521d') } 'App::Sqitch::X',
    'Revert should die on unknown change ID';
is $@->ident, 'revert', 'Should be another "revert" error';
is $@->message, __x(
    'Unknown change: "{change}"',
    change => '8d77c5f588b60bc0f2efcda6369df5cb0177521d',
), 'The message should mention it is an unknown change';
is_deeply $engine->seen, [['change_id_for', {
    change_id => '8d77c5f588b60bc0f2efcda6369df5cb0177521d',
    change  => undef,
    tag     => undef,
    project => 'sql',
}]], 'Shoudl have called change_id_for() with change ID';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Revert an undeployed change.
throws_ok { $engine->revert('@alpha') } 'App::Sqitch::X',
    'Revert should die on undeployed change';
is $@->ident, 'revert', 'Should be another "revert" error';
is $@->message, __x(
    'Change not deployed: "{change}"',
    change => '@alpha',
), 'The message should mention that the change is not deployed';
is_deeply $engine->seen,  [['change_id_for', {
    change => '',
    change_id => undef,
    tag => 'alpha',
    project => 'sql',
}]], 'change_id_for';
is_deeply +MockOutput->get_info, [], 'Nothing should have been output';

# Revert to a point with no following changes.
$offset_change = $changes[0];
push @resolved => $offset_change->id;
throws_ok { $engine->revert($changes[0]->id) } 'App::Sqitch::X',
    'Should get error reverting when no subsequent changes';
is $@->ident, 'revert', 'No subsequent change error ident should be "revert"';
is $@->exitval, 1, 'No subsequent change error exitval should be 1';
is $@->message, __x(
    'No changes deployed since: "{change}"',
    change => $changes[0]->id,
), 'No subsequent change error message should be correct';

delete $changes[0]->{_rework_tags}; # For deep comparison.
is_deeply $engine->seen, [
    [change_id_for => {
        change_id => $changes[0]->id,
        change => undef,
        tag => undef,
        project => 'sql',
    }],
    [ change_offset_from_id => [$changes[0]->id, 0] ],
    [deployed_changes_since => $changes[0]],
], 'Should have called change_id_for and deployed_changes_since';

# Revert with nothing deployed.
throws_ok { $engine->revert } 'App::Sqitch::X',
    'Should get error for known but undeployed change';
is $@->ident, 'revert', 'No changes error should be "revert"';
is $@->exitval, 1, 'No changes exitval should be 1';
is $@->message, __ 'Nothing to revert (nothing deployed)',
    'No changes message should be correct';

is_deeply $engine->seen, [
    [deployed_changes => undef],
], 'Should have called deployed_changes';

# Now revert from a deployed change.
my @dbchanges;
@deployed_changes = map {
    my $plan_change = $_;
    my $params = {
        id            => $plan_change->id,
        name          => $plan_change->name,
        project       => $plan_change->project,
        note          => $plan_change->note,
        planner_name  => $plan_change->planner_name,
        planner_email => $plan_change->planner_email,
        timestamp     => $plan_change->timestamp,
        tags          => [ map { $_->name } $plan_change->tags ],
    };
    push @dbchanges => my $db_change = App::Sqitch::Plan::Change->new(
        plan => $plan,
        %{ $params },
    );
    $db_change->add_tag( App::Sqitch::Plan::Tag->new(
        name => $_->name, plan => $plan, change => $db_change
    ) ) for $plan_change->tags;
    $db_change->tags; # Autovivify _tags For changes with no tags.
    $params;
} @changes[0..3];

MockOutput->ask_y_n_returns(1);
ok $engine->revert, 'Revert all changes';
is_deeply $engine->seen, [
    [deployed_changes => undef],
    [check_revert_dependencies => [reverse @dbchanges[0..3]] ],
    [run_file => $dbchanges[3]->revert_file ],
    [log_revert_change => $dbchanges[3] ],
    [run_file => $dbchanges[2]->revert_file ],
    [log_revert_change => $dbchanges[2] ],
    [run_file => $dbchanges[1]->revert_file ],
    [log_revert_change => $dbchanges[1] ],
    [run_file => $dbchanges[0]->revert_file ],
    [log_revert_change => $dbchanges[0] ],
], 'Should have reverted the changes in reverse order';
is_deeply +MockOutput->get_ask_y_n, [
    [__x(
        'Revert all changes from {destination}?',
        destination => $engine->destination,
    ), 'Yes'],
], 'Should have prompted to revert all changes';
is_deeply +MockOutput->get_info_literal, [
    ['  - lolz ..', '.........', ' '],
    ['  - widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '.', ' '],
    ['  - roles ..', '........', ' '],
], 'It should have said it was reverting all changes and listed them';
is_deeply +MockOutput->get_info, [
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
], 'And the revert successes should be emitted';

# Try with log-only.
ok $engine->log_only(1), 'Enable log_only';
ok $engine->revert(undef, 1), 'Revert all changes log-only';
delete @{ $_ }{qw(_path_segments _rework_tags)} for @dbchanges; # These need to be invisible.
is_deeply $engine->seen, [
    [deployed_changes => undef],
    [check_revert_dependencies => [reverse @dbchanges[0..3]] ],
    [log_revert_change => $dbchanges[3] ],
    [log_revert_change => $dbchanges[2] ],
    [log_revert_change => $dbchanges[1] ],
    [log_revert_change => $dbchanges[0] ],
], 'Log-only Should have reverted the changes in reverse order';
is_deeply +MockOutput->get_ask_y_n, [
    [__x(
        'Revert all changes from {destination}?',
        destination => $engine->destination,
    ), 'Yes'],
], 'Log-only should have prompted to revert all changes';
is_deeply +MockOutput->get_info_literal, [
    ['  - lolz ..', '.........', ' '],
    ['  - widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '.', ' '],
    ['  - roles ..', '........', ' '],
], 'It should have said it was reverting all changes and listed them';
is_deeply +MockOutput->get_info, [
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
], 'And the revert successes should be emitted';

# Should exit if the revert is declined.
MockOutput->ask_y_n_returns(0);
throws_ok { $engine->revert } 'App::Sqitch::X', 'Should abort declined revert';
is $@->ident, 'revert', 'Declined revert ident should be "revert"';
is $@->exitval, 1, 'Should have exited with value 1';
is $@->message, __ 'Nothing reverted', 'Should have exited with proper message';
is_deeply $engine->seen, [
    [deployed_changes => undef],
], 'Should have called deployed_changes only';
is_deeply +MockOutput->get_ask_y_n, [
    [__x(
        'Revert all changes from {destination}?',
        destination => $engine->destination,
    ), 'Yes'],
], 'Should have prompt to revert all changes';
is_deeply +MockOutput->get_info, [
], 'It should have emitted nothing else';

# Revert all changes with no prompt.
MockOutput->ask_y_n_returns(1);
my $no_prompt = 1;
$engine->log_only(0);
$mock_engine->mock( no_prompt => sub { $no_prompt } );
ok $engine->revert, 'Revert all changes with no prompt';
is_deeply $engine->seen, [
    [deployed_changes => undef],
    [check_revert_dependencies => [reverse @dbchanges[0..3]] ],
    [run_file => $dbchanges[3]->revert_file ],
    [log_revert_change => $dbchanges[3] ],
    [run_file => $dbchanges[2]->revert_file ],
    [log_revert_change => $dbchanges[2] ],
    [run_file => $dbchanges[1]->revert_file ],
    [log_revert_change => $dbchanges[1] ],
    [run_file => $dbchanges[0]->revert_file ],
    [log_revert_change => $dbchanges[0] ],
], 'Should have reverted the changes in reverse order';
is_deeply +MockOutput->get_ask_y_n, [], 'Should have no prompt';
is_deeply +MockOutput->get_info_literal, [
    ['  - lolz ..', '.........', ' '],
    ['  - widgets @beta ..', '', ' '],
    ['  - users @alpha ..', '.', ' '],
    ['  - roles ..', '........', ' '],
], 'It should have said it was reverting all changes and listed them';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting all changes from {destination}',
        destination => $engine->destination,
    )],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
    [__ 'ok'],
], 'And the revert successes should be emitted';

# Now just revert to an earlier change.
$no_prompt = 0;
$offset_change = $dbchanges[1];
push @resolved => $offset_change->id;
@deployed_changes = @deployed_changes[2..3];
ok $engine->revert('@alpha'), 'Revert to @alpha';

delete $dbchanges[1]->{_rework_tags}; # These need to be invisible.
is_deeply $engine->seen, [
    [change_id_for => { change_id => undef, change => '', tag => 'alpha', project => 'sql' }],
    [ change_offset_from_id => [$dbchanges[1]->id, 0] ],
    [deployed_changes_since => $dbchanges[1]],
    [check_revert_dependencies => [reverse @dbchanges[2..3]] ],
    [run_file => $dbchanges[3]->revert_file ],
    [log_revert_change => $dbchanges[3] ],
    [run_file => $dbchanges[2]->revert_file ],
    [log_revert_change => $dbchanges[2] ],
], 'Should have reverted only changes after @alpha';
is_deeply +MockOutput->get_ask_y_n, [
    [__x(
        'Revert changes to {change} from {destination}?',
        destination => $engine->destination,
        change      => $dbchanges[1]->format_name_with_tags,
    ), 'Yes'],
], 'Should have prompt to revert to change';
is_deeply +MockOutput->get_info_literal, [
    ['  - lolz ..', '.........', ' '],
    ['  - widgets @beta ..', '', ' '],
], 'Output should show what it reverts to';
is_deeply +MockOutput->get_info, [
    [__ 'ok'],
    [__ 'ok'],
], 'And the revert successes should be emitted';

MockOutput->ask_y_n_returns(0);
$offset_change = $dbchanges[1];
push @resolved => $offset_change->id;
throws_ok { $engine->revert('@alpha') } 'App::Sqitch::X',
    'Should abort declined revert to @alpha';
is $@->ident, 'revert:confirm', 'Declined revert ident should be "revert:confirm"';
is $@->exitval, 1, 'Should have exited with value 1';
is $@->message, __ 'Nothing reverted', 'Should have exited with proper message';
is_deeply $engine->seen, [
    [change_id_for => { change_id => undef, change => '', tag => 'alpha', project => 'sql' }],
    [change_offset_from_id => [$dbchanges[1]->id, 0] ],
    [deployed_changes_since => $dbchanges[1]],
], 'Should have called revert methods';
is_deeply +MockOutput->get_ask_y_n, [
    [__x(
        'Revert changes to {change} from {destination}?',
        change      => $dbchanges[1]->format_name_with_tags,
        destination => $engine->destination,
    ), 'Yes'],
], 'Should have prompt to revert to @alpha';
is_deeply +MockOutput->get_info, [
], 'It should have emitted nothing else';

# Try to revert just the last change with no prompt
MockOutput->ask_y_n_returns(1);
$no_prompt = 1;
my $rtags = delete $dbchanges[-1]->{_rework_tags}; # These need to be invisible.
$offset_change = $dbchanges[-1];
push @resolved => $offset_change->id;
@deployed_changes = $deployed_changes[-1];
ok $engine->revert('@HEAD^'), 'Revert to @HEAD^';
is_deeply $engine->seen, [
    [change_id_for => { change_id => undef, change => '', tag => 'HEAD', project => 'sql' }],
    [change_offset_from_id => [$dbchanges[-1]->id, -1] ],
    [deployed_changes_since => $dbchanges[-1]],
    [check_revert_dependencies => [{ %{ $dbchanges[-1] }, _rework_tags => $rtags }] ],
    [run_file => $dbchanges[-1]->revert_file ],
    [log_revert_change => { %{ $dbchanges[-1] }, _rework_tags => $rtags } ],
], 'Should have reverted one changes for @HEAD^';
is_deeply +MockOutput->get_ask_y_n, [], 'Should have no prompt';
is_deeply +MockOutput->get_info_literal, [
    ['  - lolz ..', '', ' '],
], 'Output should show what it reverts to';
is_deeply +MockOutput->get_info, [
    [__x(
        'Reverting changes to {change} from {destination}',
        destination => $engine->destination,
        change      => $dbchanges[-1]->format_name_with_tags,
    )],
    [__ 'ok'],
], 'And the header and "ok" should be emitted';

##############################################################################
# Test change_id_for_depend().
can_ok $CLASS, 'change_id_for_depend';

$offset_change = $dbchanges[1];
my ($dep) = $make_deps->( 1, 'foo' );
throws_ok { $engine->change_id_for_depend( $dep ) } 'App::Sqitch::X',
    'Should get error from change_id_for_depend when change not in plan';
is $@->ident, 'plan', 'Should get ident "plan" from change_id_for_depend';
is $@->message, __x(
    'Unable to find change "{change}" in plan {file}',
    change => $dep->key_name,
    file   => $sqitch->plan_file,
), 'Should have proper message from change_id_for_depend error';

PLANOK: {
    my $mock_depend = Test::MockModule->new('App::Sqitch::Plan::Depend');
    $mock_depend->mock(id     => sub { undef });
    $mock_depend->mock(change => sub { undef });
    throws_ok { $engine->change_id_for_depend( $dep ) } 'App::Sqitch::X',
        'Should get error from change_id_for_depend when no ID';
    is $@->ident, 'engine', 'Should get ident "engine" when no ID';
    is $@->message, __x(
        'Invalid dependency: {dependency}',
        dependency => $dep->as_string,
    ), 'Should have proper messag from change_id_for_depend error';

    # Let it have the change.
    $mock_depend->unmock('change');

    push @resolved => $changes[1]->id;
    is $engine->change_id_for_depend( $dep ), $changes[1]->id,
        'Get a change id';
    is_deeply $engine->seen, [
        [change_id_for => {
            change_id => $dep->id,
            change    => $dep->change,
            tag       => $dep->tag,
            project   => $dep->project,
        }],
    ], 'Should have passed dependency params to change_id_for()';
}

##############################################################################
# Test find_change().
can_ok $CLASS, 'find_change';
push @resolved => $dbchanges[1]->id;
is $engine->find_change(
    change_id => $resolved[0],
    change    => 'hi',
    tag       => 'yo',
), $dbchanges[1], 'find_change() should work';
is_deeply $engine->seen, [
    [change_id_for => {
        change_id => $dbchanges[1]->id,
        change    => 'hi',
        tag       => 'yo',
        project   => 'sql',
    }],
    [change_offset_from_id => [ $dbchanges[1]->id, undef ]],
], 'Its parameters should have been passed to change_id_for and change_offset_from_id';

# Pass a project and an ofset.
push @resolved => $dbchanges[1]->id;
is $engine->find_change(
    change    => 'hi',
    offset    => 1,
    project   => 'fred',
), $dbchanges[1], 'find_change() should work';
is_deeply $engine->seen, [
    [change_id_for => {
        change_id => undef,
        change    => 'hi',
        tag       => undef,
        project   => 'fred',
    }],
    [change_offset_from_id => [ $dbchanges[1]->id, 1 ]],
], 'Project and offset should have been passed off';

##############################################################################
# Test verify_change().
can_ok $CLASS, 'verify_change';
$change = App::Sqitch::Plan::Change->new( name => 'users', plan => $sqitch->plan );
ok $engine->verify_change($change), 'Verify a change';
is_deeply $engine->seen, [
    [run_file => $change->verify_file ],
], 'The change file should have been run';
is_deeply +MockOutput->get_info, [], 'Should have no info output';

# Try a change with no verify script.
$change = App::Sqitch::Plan::Change->new( name => 'roles', plan => $sqitch->plan );
ok $engine->verify_change($change), 'Verify a change with no verify script.';
is_deeply $engine->seen, [], 'No abstract methods should be called';
is_deeply +MockOutput->get_info, [], 'Should have no info output';
is_deeply +MockOutput->get_vent, [
    [__x 'Verify script {file} does not exist', file => $change->verify_file],
], 'A warning about no verify file should have been emitted';

##############################################################################
# Test check_deploy_dependenices().
$mock_engine->unmock('check_deploy_dependencies');
can_ok $engine, 'check_deploy_dependencies';

CHECK_DEPLOY_DEPEND: {
    # Make sure dependencies check out for all the existing changes.
    $plan->reset;
    ok $engine->check_deploy_dependencies($plan),
        'All planned changes should be okay';
    is_deeply $engine->seen, [
        [ are_deployed_changes => [map { $plan->change_at($_) } 0..$plan->count - 1] ],
    ], 'Should have called are_deployed_changes';

    # Make sure it works when depending on a previous change.
    my $change = $plan->change_at(3);
    push @{ $change->_requires } => $make_deps->( 0, 'users' );
    ok $engine->check_deploy_dependencies($plan),
        'Dependencies should check out even when within those to be deployed';
    is_deeply [ map { $_->resolved_id } map { $_->requires } $plan->changes ],
        [ $plan->change_at(1)->id ],
        'Resolved ID should be populated';

    # Make sure it fails if there is a conflict within those to be deployed.
    push @{ $change->_conflicts } => $make_deps->( 1, 'widgets' );
    throws_ok { $engine->check_deploy_dependencies($plan) } 'App::Sqitch::X',
        'Conflict should throw exception';
    is $@->ident, 'deploy', 'Should be a "deploy" error';
    is $@->message, __nx(
        'Conflicts with previously deployed change: {changes}',
        'Conflicts with previously deployed changes: {changes}',
        scalar 1,
        changes => 'widgets',
    ), 'Should have localized message about the local conflict';
    shift @{ $change->_conflicts };

    # Now test looking stuff up in the database.
    my $mock_depend = Test::MockModule->new('App::Sqitch::Plan::Depend');
    my @depend_ids;
    $mock_depend->mock(id => sub { shift @depend_ids });

    my @conflicts = $make_deps->( 1, qw(foo bar) );
    $change = App::Sqitch::Plan::Change->new(
        name      => 'foo',
        plan      => $sqitch->plan,
        conflicts => \@conflicts,
    );
    $plan->_changes->append($change);

    my $start_from = $plan->count - 1;
    $plan->position( $start_from - 1);
    push @resolved, '2342', '253245';
    throws_ok { $engine->check_deploy_dependencies($plan, $start_from) } 'App::Sqitch::X',
        'Conflict should throw exception';
    is $@->ident, 'deploy', 'Should be a "deploy" error';
    is $@->message, __nx(
        'Conflicts with previously deployed change: {changes}',
        'Conflicts with previously deployed changes: {changes}',
        scalar 2,
        changes => 'foo bar',
    ), 'Should have localized message about conflicts';

    is_deeply $engine->seen, [
        [ are_deployed_changes => [map { $plan->change_at($_) } 0..$start_from-1] ],
        [ change_id_for => {
            change_id => undef,
            change    => 'foo',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'bar',
            tag       => undef,
            project   => 'sql',
        } ],
    ], 'Should have called change_id_for() twice';
    is_deeply [ map { $_->resolved_id } @conflicts ], [undef, undef],
        'Conflicting dependencies should have no resolved IDs';

    # Fail with multiple conflicts.
    push @{ $plan->change_at(3)->_conflicts } => $make_deps->( 1, 'widgets' );
    $plan->reset;
    push @depend_ids => $plan->change_at(2)->id;
    push @resolved, '2342', '253245', '2323434';
    throws_ok { $engine->check_deploy_dependencies($plan) } 'App::Sqitch::X',
        'Conflict should throw another exception';
    is $@->ident, 'deploy', 'Should be a "deploy" error';
    is $@->message, __nx(
        'Conflicts with previously deployed change: {changes}',
        'Conflicts with previously deployed changes: {changes}',
        scalar 3,
        changes => 'widgets foo bar',
    ), 'Should have localized message about all three conflicts';

    is_deeply $engine->seen, [
        [ change_id_for => {
            change_id => undef,
            change    => 'users',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'foo',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'bar',
            tag       => undef,
            project   => 'sql',
        } ],
    ], 'Should have called change_id_for() twice';
    is_deeply [ map { $_->resolved_id } @conflicts ], [undef, undef],
        'Conflicting dependencies should have no resolved IDs';

    ##########################################################################
    # Die on missing dependencies.
    my @requires = $make_deps->( 0, qw(foo bar) );
    $change = App::Sqitch::Plan::Change->new(
        name      => 'blah',
        plan      => $sqitch->plan,
        requires  => \@requires,
    );
    $plan->_changes->append($change);
    $start_from = $plan->count - 1;
    $plan->position( $start_from - 1);

    push @resolved, undef, undef;
    throws_ok { $engine->check_deploy_dependencies($plan, $start_from) } 'App::Sqitch::X',
        'Missing dependencies should throw exception';
    is $@->ident, 'deploy', 'Should be another "deploy" error';
    is $@->message, __nx(
        'Missing required change: {changes}',
        'Missing required changes: {changes}',
        scalar 2,
        changes => 'foo bar',
    ), 'Should have localized message missing dependencies';

    is_deeply $engine->seen, [
        [ change_id_for => {
            change_id => undef,
            change    => 'foo',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'bar',
            tag       => undef,
            project   => 'sql',
        } ],
    ], 'Should have called check_requires';
    is_deeply [ map { $_->resolved_id } @requires ], [undef, undef],
        'Missing requirements should not have resolved';

    # Make sure we see both conflict and prereq failures.
    push @resolved, '2342', '253245', '2323434', undef, undef;
    $plan->reset;

    throws_ok { $engine->check_deploy_dependencies($plan, $start_from) } 'App::Sqitch::X',
        'Missing dependencies should throw exception';
    is $@->ident, 'deploy', 'Should be another "deploy" error';
    is $@->message, join(
        "\n",
        __nx(
            'Conflicts with previously deployed change: {changes}',
            'Conflicts with previously deployed changes: {changes}',
            scalar 3,
            changes => 'widgets foo',
        ),
        __nx(
            'Missing required change: {changes}',
            'Missing required changes: {changes}',
            scalar 2,
            changes => 'foo bar',
        ),
    ), 'Should have localized conflicts and required error messages';

    is_deeply $engine->seen, [
        [ change_id_for => {
            change_id => undef,
            change    => 'widgets',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'users',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'foo',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'bar',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'foo',
            tag       => undef,
            project   => 'sql',
        } ],
        [ change_id_for => {
            change_id => undef,
            change    => 'bar',
            tag       => undef,
            project   => 'sql',
        } ],
    ], 'Should have called check_requires';
    is_deeply [ map { $_->resolved_id } @requires ], [undef, undef],
        'Missing requirements should not have resolved';
}

# Test revert dependency-checking.
$mock_engine->unmock('check_revert_dependencies');
can_ok $engine, 'check_revert_dependencies';

CHECK_REVERT_DEPEND: {
    my $change = App::Sqitch::Plan::Change->new(
        name      => 'urfa',
        id        => '24234234234e',
        plan      => $plan,
    );

    # Have revert change fail with requiring changes.
    my $req = {
        change_id => '23234234',
        change    => 'blah',
        asof_tag  => undef,
        project   => $plan->project,
    };
    @requiring = [$req];

    throws_ok { $engine->check_revert_dependencies($change) } 'App::Sqitch::X',
        'Should get error reverting change another depend on';
    is $@->ident, 'revert', 'Dependent error ident should be "revert"';
    is $@->message, __nx(
        'Change "{change}" required by currently deployed change: {changes}',
        'Change "{change}" required by currently deployed changes: {changes}',
        1,
        change  => 'urfa',
        changes => 'blah'
    ), 'Dependent error message should be correct';
    is_deeply $engine->seen, [
        [changes_requiring_change => $change ],
    ], 'It should have check for requiring changes';

    # Add a second requiring change.
    my $req2 = {
        change_id => '99999',
        change    => 'harhar',
        asof_tag  => '@foo',
        project   => 'elsewhere',
    };
    @requiring = [$req, $req2];

    throws_ok { $engine->check_revert_dependencies($change) } 'App::Sqitch::X',
        'Should get error reverting change others depend on';
    is $@->ident, 'revert', 'Dependent error ident should be "revert"';
    is $@->message, __nx(
        'Change "{change}" required by currently deployed change: {changes}',
        'Change "{change}" required by currently deployed changes: {changes}',
        2 ,
        change  => 'urfa',
        changes => 'blah elsewhere:harhar@foo'
    ), 'Dependent error message should be correct';
    is_deeply $engine->seen, [
        [changes_requiring_change => $change ],
    ], 'It should have check for requiring changes';

    # Try it with two changes.
    my $req3 = {
        change_id => '94949494',
        change    => 'frobisher',
        project   => 'whu',
    };
    @requiring = ([$req, $req2], [$req3]);

    my $change2 = App::Sqitch::Plan::Change->new(
        name      => 'kazane',
        id        => '8686868686',
        plan      => $plan,
    );

    throws_ok { $engine->check_revert_dependencies($change, $change2) } 'App::Sqitch::X',
        'Should get error reverting change others depend on';
    is $@->ident, 'revert', 'Dependent error ident should be "revert"';
    is $@->message, join(
        "\n",
        __nx(
            'Change "{change}" required by currently deployed change: {changes}',
            'Change "{change}" required by currently deployed changes: {changes}',
            2 ,
            change  => 'urfa',
            changes => 'blah elsewhere:harhar@foo'
        ),
        __nx(
            'Change "{change}" required by currently deployed change: {changes}',
            'Change "{change}" required by currently deployed changes: {changes}',
            1,
            change  => 'kazane',
            changes => 'whu:frobisher'
        ),
    ), 'Dependent error message should be correct';
    is_deeply $engine->seen, [
        [changes_requiring_change => $change ],
        [changes_requiring_change => $change2 ],
    ], 'It should have checked twice for requiring changes';
}

##############################################################################
# Test _trim_to().
can_ok $engine, '_trim_to';

# Should get an error when a change is not in the plan.
throws_ok { $engine->_trim_to( 'foo', 'nonexistent', [] ) } 'App::Sqitch::X',
    '_trim_to should complain about a nonexistent change key';
is $@->ident, 'foo', '_trim_to nonexistent key error ident should be "foo"';
is $@->message, __x(
    'Cannot find "{change}" in the database or the plan',
    change => 'nonexistent',
), '_trim_to nonexistent key error message should be correct';

# Should get an error when it's in the plan but not the database.
throws_ok { $engine->_trim_to( 'yep', 'blah', [] ) } 'App::Sqitch::X',
    '_trim_to should complain about an undeployed change key';
is $@->ident, 'yep', '_trim_to undeployed change error ident should be "yep"';
is $@->message, __x(
    'Change "{change}" has not been deployed',
    change => 'blah',
), '_trim_to undeployed change error message should be correct';

# Should get an error when it's deployed but not in the plan.
@resolved = ('whatever');
throws_ok { $engine->_trim_to( 'oop', 'whatever', [] ) } 'App::Sqitch::X',
    '_trim_to should complain about an unplanned change key';
is $@->ident, 'oop', '_trim_to unplanned change error ident should be "oop"';
is $@->message, __x(
    'Change "{change}" is deployed, but not planned',
    change => 'whatever',
), '_trim_to unplanned change error message should be correct';

# Let's mess with changes. Start by shifting nothing.
my $to_trim = [@changes];
@resolved   = ($changes[0]->id);
my $key     = $changes[0]->name;
is $engine->_trim_to('foo', $key, $to_trim), 0,
    qq{_trim_to should find "$key" at index 0};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes ],
    'Changes should be untrimmed';

# Try shifting to the third change.
$to_trim  = [@changes];
@resolved = ($changes[2]->id);
$key      = $changes[2]->name;
is $engine->_trim_to('foo', $key, $to_trim), 2,
    qq{_trim_to should find "$key" at index 2};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[2..$#changes] ],
    'First two changes should be shifted off';

# Try poppipng nothing.
$to_trim  = [@changes];
@resolved = ($changes[-1]->id);
$key      = $changes[-1]->name;
is $engine->_trim_to('foo', $key, $to_trim, 1), $#changes,
    qq{_trim_to should find "$key" at last index};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes ],
    'Changes should be untrimmed';

# Try shifting to the third-to-last change.
$to_trim  = [@changes];
@resolved = ($changes[-3]->id);
$key      = $changes[-3]->name;
is $engine->_trim_to('foo', $key, $to_trim, 1), 4,
    qq{_trim_to should find "$key" at index 4};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[0..$#changes-2] ],
    'Last two changes should be popped off';

# @HEAD and HEAD should be handled relative to deployed changes, not the plan.
$to_trim  = [@changes];
@resolved = ($changes[2]->id);
$key      = '@HEAD';
is $engine->_trim_to('foo', $key, $to_trim), 2,
    qq{_trim_to should find "$key" at index 2};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[2..$#changes] ],
    'First two changes should be shifted off';

$to_trim  = [@changes];
@resolved = ($changes[2]->id);
$key      = 'HEAD';
is $engine->_trim_to('foo', $key, $to_trim), 2,
    qq{_trim_to should find "$key" at index 2};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[2..$#changes] ],
    'First two changes should be shifted off';

# @ROOT and ROOT should be handled relative to deployed changes, not the plan.
$to_trim  = [@changes];
@resolved = ($changes[2]->id);
$key      = '@ROOT';
is $engine->_trim_to('foo', $key, $to_trim, 1), 2,
    qq{_trim_to should find "$key" at index 2};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[0,1,2] ],
    'All but First three changes should be popped off';

$to_trim  = [@changes];
@resolved = ($changes[2]->id);
$key      = 'ROOT';
is $engine->_trim_to('foo', $key, $to_trim, 1), 2,
    qq{_trim_to should find "$key" at index 2};
is_deeply [ map { $_->id } @{ $to_trim } ], [ map { $_->id } @changes[0,1,2] ],
    'All but First three changes should be popped off';

##############################################################################
# Test _verify_changes().
can_ok $engine, '_verify_changes';
$engine->seen;

# Start with a single change with a valid verify script.
is $engine->_verify_changes(1, 1, 0, $changes[1]), 0,
    'Verify of a single change should return errcount 0';
is_deeply +MockOutput->get_emit_literal, [[
    '  * users @alpha ..', '', ' ',
]], 'Declared output should list the change';
is_deeply +MockOutput->get_emit, [['ok']],
    'Emitted Output should reflect the verification of the change';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply $engine->seen, [
    [run_file => $changes[1]->verify_file ],
], 'The verify script should have been run';

# Try a single change with no verify script.
is $engine->_verify_changes(0, 0, 0, $changes[0]), 0,
    'Verify of another single change should return errcount 0';
is_deeply +MockOutput->get_emit_literal, [[
    '  * roles ..', '', ' ',
]], 'Declared output should list the change';
is_deeply +MockOutput->get_emit, [['ok']],
    'Emitted Output should reflect the verification of the change';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [
    [__x 'Verify script {file} does not exist', file => $changes[0]->verify_file],
], 'A warning about no verify file should have been emitted';
is_deeply $engine->seen, [
], 'The verify script should not have been run';

# Try multiple changes.
is $engine->_verify_changes(0, 1, 0, @changes[0,1]), 0,
    'Verify of two changes should return errcount 0';
is_deeply +MockOutput->get_emit_literal, [
    ['  * roles ..', '.......', ' '],
    ['  * users @alpha ..', '', ' '],
], 'Declared output should list both changes';
is_deeply +MockOutput->get_emit, [['ok'], ['ok']],
    'Emitted Output should reflect the verification of the changes';

is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [
    [__x 'Verify script {file} does not exist', file => $changes[0]->verify_file],
], 'A warning about no verify file should have been emitted';
is_deeply $engine->seen, [
    [run_file => $changes[1]->verify_file ],
], 'Only one verify script should have been run';

# Try multiple changes and show undeployed changes.
my @plan_changes = $plan->changes;
is $engine->_verify_changes(0, 1, 1, @changes[0,1]), 0,
    'Verify of two changes and show pending';
is_deeply +MockOutput->get_emit_literal, [
    ['  * roles ..', '.......', ' '],
    ['  * users @alpha ..', '', ' '],
], 'Delcared output should list deployed changes';
is_deeply +MockOutput->get_emit, [
    ['ok'], ['ok'],
    [__n 'Undeployed change:', 'Undeployed changes:', 2],
    map { [ '  * ', $_->format_name_with_tags] } @plan_changes[2..$#plan_changes]
], 'Emitted output should include list of pending changes';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [
    [__x 'Verify script {file} does not exist', file => $changes[0]->verify_file],
], 'A warning about no verify file should have been emitted';
is_deeply $engine->seen, [
    [run_file => $changes[1]->verify_file ],
], 'Only one verify script should have been run';

# Try a change that is not in the plan.
$change = App::Sqitch::Plan::Change->new( name => 'nonexistent', plan => $plan );
is $engine->_verify_changes(1, 0, 0, $change), 1,
    'Verify of a change not in the plan should return errcount 1';
is_deeply +MockOutput->get_emit_literal, [[
    '  * nonexistent ..', '', ' '
]], 'Declared Output should reflect the verification of the change';
is_deeply +MockOutput->get_emit, [['not ok']],
    'Emitted Output should reflect the failure of the verify';
is_deeply +MockOutput->get_comment, [[__ 'Not present in the plan' ]],
    'Should have a comment about the change missing from the plan';
is_deeply $engine->seen, [], 'No verify script should have been run';

# Try a change in the wrong place in the plan.
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(index_of => 5);
is $engine->_verify_changes(1, 0, 0, $changes[1]), 1,
    'Verify of an out-of-order change should return errcount 1';
is_deeply +MockOutput->get_emit_literal, [
    ['  * users @alpha ..', '', ' '],
], 'Declared output should reflect the verification of the change';
is_deeply +MockOutput->get_emit, [['not ok']],
    'Emitted Output should reflect the failure of the verify';
is_deeply +MockOutput->get_comment, [[__ 'Out of order' ]],
    'Should have a comment about the out-of-order change';
is_deeply $engine->seen, [
    [run_file => $changes[1]->verify_file ],
], 'The verify script should have been run';

# Make sure that multiple issues add up.
$mock_engine->mock( verify_change => sub { hurl 'WTF!' });
is $engine->_verify_changes(1, 0, 0, $changes[1]), 2,
    'Verify of a change with 2 issues should return 2';
is_deeply +MockOutput->get_emit_literal, [
    ['  * users @alpha ..', '', ' '],
], 'Declared output should reflect the verification of the change';
is_deeply +MockOutput->get_emit, [['not ok']],
    'Emitted Output should reflect the failure of the verify';
is_deeply +MockOutput->get_comment, [
    [__ 'Out of order' ],
    ['WTF!'],
], 'Should have comment about the out-of-order change and script failure';
is_deeply $engine->seen, [], 'No abstract methods should have been called';

# Make sure that multiple changes with multiple issues add up.
$mock_engine->mock( verify_change => sub { hurl 'WTF!' });
is $engine->_verify_changes(0, -1, 0, @changes[0,1]), 4,
    'Verify of 2 changes with 2 issues each should return 4';
is_deeply +MockOutput->get_emit_literal, [
    ['  * roles ..', '.......', ' '],
    ['  * users @alpha ..', '', ' '],
], 'Declraed output should reflect the verification of both changes';
is_deeply +MockOutput->get_emit, [['not ok'], ['not ok']],
    'Emitted Output should reflect the failure of both verifies';
is_deeply +MockOutput->get_comment, [
    [__ 'Out of order' ],
    ['WTF!'],
    [__ 'Out of order' ],
    ['WTF!'],
], 'Should have comment about the out-of-order changes and script failures';
is_deeply $engine->seen, [], 'No abstract methods should have been called';

# Unmock before moving on.
$mock_plan->unmock('index_of');
$mock_engine->unmock('verify_change');

# Now deal with changes in the plan but not in the list.
is $engine->_verify_changes($#changes, $plan->count - 1, 0, $changes[-1]), 2,
    '_verify_changes with two undeployed changes should returne 2';
is_deeply +MockOutput->get_emit_literal, [
    ['  * dr_evil ..', '', ' '],
    ['  * foo ..', '....', ' ' , 'not ok', ' '],
    ['  * blah ..', '...', ' ' , 'not ok', ' '],
], 'Listed changes should be both deployed and undeployed';
is_deeply +MockOutput->get_emit, [['ok']],
    'Emitted Output should reflect 1 pass';
is_deeply +MockOutput->get_comment, [
    [__ 'Not deployed' ],
    [__ 'Not deployed' ],
], 'Should have comments for undeployed changes';
is_deeply $engine->seen, [], 'No abstract methods should have been called';

##############################################################################
# Test verify().
can_ok $engine, 'verify';
my @verify_changes;
$mock_engine->mock( _load_changes => sub { @verify_changes });

# First, test with no changes.
throws_ok { $engine->verify } 'App::Sqitch::X',
    'Should get error for no deployed changes';
is $@->ident, 'verify', 'No deployed changes ident should be "verify"';
is $@->exitval, 1, 'No deployed changes exitval should be 1';
is $@->message, __ 'No changes deployed',
    'No deployed changes message should be correct';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';

# Try no changes *and* nothing in the plan.
my $count = 0;
$mock_plan->mock(count => sub { $count });
throws_ok { $engine->verify } 'App::Sqitch::X',
    'Should get error for no changes';
is $@->ident, 'verify', 'No changes ident should be "verify"';
is $@->exitval, 1, 'No changes exitval should be 1';
is $@->message, __ 'Nothing to verify (no planned or deployed changes)',
    'No changes message should be correct';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';

# Now return some changes but have nothing in the plan.
@verify_changes = @changes;
throws_ok { $engine->verify } 'App::Sqitch::X',
    'Should get error for no planned changes';
is $@->ident, 'verify', 'No planned changes ident should be "verify"';
is $@->exitval, 2, 'No planned changes exitval should be 2';
is $@->message, __ 'There are deployed changes, but none planned!',
    'No planned changes message should be correct';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';

# Let's do one change and have it pass.
$mock_plan->mock(index_of => 0);
$count = 1;
@verify_changes = ($changes[1]);
undef $@;
ok $engine->verify, 'Verify one change';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';
is_deeply +MockOutput->get_emit_literal, [
    ['  * ' . $changes[1]->format_name_with_tags . ' ..', '', ' ' ],
], 'The one change name should be declared';
is_deeply +MockOutput->get_emit, [
    ['ok'],
    [__ 'Verify successful'],
], 'Success should be emitted';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';

# Verify two changes.
MockOutput->get_vent;
$mock_plan->unmock('index_of');
@verify_changes = @changes[0,1];
ok $engine->verify, 'Verify two changes';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';
is_deeply +MockOutput->get_emit_literal, [
    ['  * roles ..', '.......', ' ' ],
    ['  * users @alpha ..', '', ' ' ],
], 'The two change names should be declared';
is_deeply +MockOutput->get_emit, [
    ['ok'], ['ok'],
    [__ 'Verify successful'],
], 'Both successes should be emitted';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [
    [__x(
        'Verify script {file} does not exist',
        file => $changes[0]->verify_file,
    )]
], 'Should have warning about missing verify script';

# Make sure a reworked change (that is, one with a suffix) is ignored.
my $mock_change = Test::MockModule->new(ref $change);
$mock_change->mock(is_reworked => 1);
@verify_changes = @changes[0,1];
ok $engine->verify, 'Verify with a reworked change changes';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';
is_deeply +MockOutput->get_emit_literal, [
    ['  * roles ..', '.......', ' ' ],
    ['  * users @alpha ..', '', ' ' ],
], 'The two change names should be emitted';
is_deeply +MockOutput->get_emit, [
    ['ok'], ['ok'],
    [__ 'Verify successful'],
], 'Both successes should be emitted';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [], 'Should have no warnings';

$mock_change->unmock('is_reworked');

# Make sure we can trim.
@verify_changes = @changes;
@resolved   = map { $_->id } @changes[1,2];
ok $engine->verify('users', 'widgets'), 'Verify two specific changes';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';
is_deeply +MockOutput->get_emit_literal, [
    ['  * users @alpha ..', '.', ' ' ],
    ['  * widgets @beta ..', '', ' ' ],
], 'The two change names should be emitted';
is_deeply +MockOutput->get_emit, [
    ['ok'], ['ok'],
    [__ 'Verify successful'],
], 'Both successes should be emitted';
is_deeply +MockOutput->get_comment, [], 'Should have no comments';
is_deeply +MockOutput->get_vent, [
    [__x(
        'Verify script {file} does not exist',
        file => $changes[2]->verify_file,
    )]
], 'Should have warning about missing verify script';

# Now fail!
$mock_engine->mock( verify_change => sub { hurl 'WTF!' });
@verify_changes = @changes;
@resolved   = map { $_->id } @changes[1,2];
throws_ok { $engine->verify('users', 'widgets') } 'App::Sqitch::X',
    'Should get failure for failing verify scripts';
is $@->ident, 'verify', 'Failed verify ident should be "verify"';
is $@->exitval, 2, 'Failed verify exitval should be 2';
is $@->message, __ 'Verify failed', 'Faield verify message should be correct';
is_deeply +MockOutput->get_info, [
    [__x 'Verifying {destination}', destination => $engine->destination],
], 'Notification of the verify should be emitted';
my $msg = __ 'Verify Summary Report';
is_deeply +MockOutput->get_emit_literal, [
    ['  * users @alpha ..', '.', ' ' ],
    ['  * widgets @beta ..', '', ' ' ],
], 'Both change names should be declared';
is_deeply +MockOutput->get_emit, [
    ['not ok'], ['not ok'],
    [ "\n", $msg ],
    [ '-' x length $msg ],
    [__x 'Changes: {number}', number => 2 ],
    [__x 'Errors:  {number}', number => 2 ],
], 'Output should include the failure report';
is_deeply +MockOutput->get_comment, [
    ['WTF!'],
    ['WTF!'],
], 'Should have the errors in comments';
is_deeply +MockOutput->get_vent, [], 'Nothing should have been vented';

__END__
diag $_->format_name_with_tags for @changes;
diag '======';
diag $_->format_name_with_tags for $plan->changes;
