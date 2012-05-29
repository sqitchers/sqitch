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
    execute
);

my $sqitch = App::Sqitch->new(
    plan_file => file(qw(t sql sqitch.plan)),
    sql_dir   => dir(qw(t sql)),
    _engine   => 'sqlite',
);

isa_ok my $deploy = $CLASS->new(sqitch => $sqitch), $CLASS;

is $deploy->to, undef, 'to should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my $init = 0;
my $curr_tag = undef;
my %called;
$mock_engine->mock(initialized => sub { $called{initialized} = 1; $init });
$mock_engine->mock(initialize  => sub { $called{initialize}  = 1; shift });
$mock_engine->mock(deploy      => sub { push @{ $called{deploy} }, $_[1]->name; shift });
$mock_engine->mock(apply       => sub { push @{ $called{deploy} }, '@' . $_[1]->name; shift });
$mock_engine->mock(current_tag_name => sub { $called{current_tag} = 1; $curr_tag });

throws_ok { $deploy->execute('alpha') } qr/^FAIL/,
    'Should get an error for nonexistent target';
is_deeply +MockOutput->get_fail, [[qq{Unknown deploy target: "alpha"}]],
    'Failure should be output';

ok $deploy->execute('@alpha'), 'Deploy to "@alpha"';
ok delete $called{initialized}, 'Should have called initialized()';
ok delete $called{initialize},  'Should have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy}, [qw(roles users @alpha)],
    'Alpha should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Deploy all.
ok $deploy->execute(), 'Deploy default';
ok delete $called{initialized}, 'Should have called initialized()';
ok delete $called{initialize},  'Should have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy},
    [qw(roles users @alpha widgets @beta)], 'Alpha and beta should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Deploy just one step.
ok $deploy->execute('roles'), 'Deploy "roles"';
ok delete $called{initialized}, 'Should have called initialized()';
ok delete $called{initialize},  'Should have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy},
    [qw(roles)], 'Only "roles" step should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Deploy from alpha.
$curr_tag = '@alpha';
ok $deploy->execute(), 'Deploy default again';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy},
    [qw(widgets @beta)], 'Only beta step should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Deploy to 'beta', but using it as an attribute.
isa_ok $deploy = $CLASS->new(sqitch => $sqitch, to => '@beta'), $CLASS;
ok $deploy->execute(), 'Deploy default again';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy},
    [qw(widgets @beta)], 'Only beta step should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Now try deploying just the tag from a step.
$curr_tag = 'widgets';
ok $deploy->execute(), 'Deploy default again';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is_deeply delete $called{deploy},
    [qw(@beta)], 'Only beta should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Now try to deploy to the current tag.
$curr_tag = '@beta';
ok $deploy->execute, 'Deploy default once more';
is_deeply +MockOutput->get_info, [
    ['Nothing to deploy (already at @beta)'],
], '"Already at beta" should have been emitted';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is $called{deploy}, undef, 'Nothing should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

ok $deploy = $CLASS->new(sqitch => $sqitch), 'Create deploy command again';
ok $deploy->execute, 'Deploy default once more';
is_deeply +MockOutput->get_info, [
    ['Nothing to deploy (up-to-date)'],
], 'Up-to-dateness should have been emitted';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is $called{deploy}, undef, 'Nothing should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Try to deploy to an earlier tag.
throws_ok { $deploy->execute('@alpha') } qr/^FAIL:/,
    'Should die trying to deploy an earlier tag';
is_deeply +MockOutput->get_fail, [
    ['Cannot deploy to an earlier target; use "revert" instead'],
], 'Error message should have been emitted';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is $called{deploy}, undef, 'Nothing should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

# Try to deploy to an earlier step.
throws_ok { $deploy->execute('widgets') } qr/^FAIL:/,
    'Should die trying to deploy an earlier step';
is_deeply +MockOutput->get_fail, [
    ['Cannot deploy to an earlier target; use "revert" instead'],
], 'Error message should have been emitted';
ok !delete $called{initialized}, 'Should not have called initialized()';
ok !delete $called{initialize},  'Should not have called initialize()';
ok delete $called{current_tag},  'Should have called current_tag()';
is $called{deploy}, undef, 'Nothing should have been deployed';
is_deeply \%called, {}, 'Nothing else should have been called';

done_testing;
