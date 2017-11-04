#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Path::Class;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use Test::MockModule;
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::show';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(execute exists_only target);

is_deeply [$CLASS->options], [qw(
    target|t=s
    exists|e!
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    options => {
        plan_file    => file(qw(t engine sqitch.plan))->stringify,
        top_dir      => dir(qw(t engine))->stringify,
        reworked_dir => dir(qw(t engine reworked))->stringify,
        engine       => 'pg',
    },
);

isa_ok my $show = $CLASS->new(sqitch => $sqitch), $CLASS;
ok !$show->exists_only, 'exists_only should be false by default';

ok my $eshow = $CLASS->new(sqitch => $sqitch, exists_only => 1),
    'Construct with exists_only';
ok $eshow->exists_only, 'exists_only should be set';

##############################################################################
# Test configure().
my $config = $sqitch->config;
is_deeply $CLASS->configure($config, {}), {},
    'Should get empty hash for no config or options';

is_deeply $CLASS->configure($config, {exists => 1}), { exists_only => 1 },
    'Should get exists_only => 1 for exist in options';

##############################################################################
# Start with the change.
ok my $change = $show->default_target->plan->get('widgets'), 'Get a change';

ok $show->execute( change => $change->id ), 'Find change by id';
is_deeply +MockOutput->get_emit, [[ $change->info ]],
    'The change info should have been emitted';

# Try by name.
ok $show->execute( change => $change->name ), 'Find change by name';
is_deeply +MockOutput->get_emit, [[ $change->info ]],
    'The change info should have been emitted again';

# What happens for something unknown?
throws_ok { $show->execute( change => 'nonexistent' ) } 'App::Sqitch::X',
    'Should get an error for an unknown change';
is $@->ident, 'show', 'Unknown change error ident should be "show"';
is $@->message, __x('Unknown change "{change}"', change => 'nonexistent'),
    'Should get proper error for unknown change';

# What about with exists_only?
ok !$eshow->execute( change => 'nonexistent' ),
    'Should return false for uknown change and exists_only';
is_deeply +MockOutput->get_emit, [], 'Nothing should have been emitted';

# Let's find a change by tag.
my $tag = ($show->default_target->plan->tags)[0];
$change = $tag->change;
ok $show->execute( change => $tag->id ), 'Find change by tag id';
is_deeply +MockOutput->get_emit, [[ $change->info ]],
    'The change info should have been emitted';

# And the tag name.
ok $show->execute( change => $tag->format_name ), 'Find change by tag';
is_deeply +MockOutput->get_emit, [[ $change->info ]],
    'The change info should have been emitted';

# Make sure it works with exists_only.
ok $eshow->execute( change => $change->id ), 'Run exists with ID';
is_deeply +MockOutput->get_emit, [],
    'There should be no output';

# Great, let's look a the tag itself.
ok $show->execute( tag => $tag->id ), 'Find tag by id';
is_deeply +MockOutput->get_emit, [[ $tag->info ]],
    'The tag info should have been emitted';

# Should work with exists_only, too.
ok $eshow->execute( tag => $tag->id ), 'Find tag by id with exists_only';
is_deeply +MockOutput->get_emit, [], 'Nothing should have been emitted';

ok $show->execute( tag => $tag->name ), 'Find tag by name';
is_deeply +MockOutput->get_emit, [[ $tag->info ]],
    'The tag info should have been emitted';

ok $show->execute( tag => $tag->format_name ), 'Find tag by formatted name';
is_deeply +MockOutput->get_emit, [[ $tag->info ]],
    'The tag info should have been emitted';

# Try an invalid tag.
throws_ok { $show->execute( tag => 'nope') } 'App::Sqitch::X',
    'Should get error for non-existent tag';
is $@->ident, 'show', 'Unknown tag error ident should be "show"';
is $@->message, __x('Unknown tag "{tag}"', tag => 'nope' ),
    'Should get proper error for unknown tag';

# Try invalid tag with exists_only.
ok !$eshow->execute( tag => 'nope'),
    'Should return false for non-existent tag and exists_only';
is_deeply +MockOutput->get_emit, [], 'Nothing should have been emitted';

# Also an invalid sha1.
throws_ok { $show->execute( tag => '7ecba288708307ef714362c121691de02ffb364d') }
    'App::Sqitch::X',
    'Should get error for non-existent tag ID';
is $@->ident, 'show', 'Unknown tag ID error ident should be "show"';
is $@->message, __x('Unknown tag "{tag}"', tag => '7ecba288708307ef714362c121691de02ffb364d' ),
    'Should get proper error for unknown tag ID';

# Now let's look at files.
ok $show->execute(deploy => $change->id), 'Show a deploy file';
is_deeply +MockOutput->get_emit, [[ $change->deploy_file->slurp(iomode => '<:raw') ]],
    'The deploy file should have been emitted';

# With exists_only.
ok $eshow->execute(deploy => $change->id), 'Show a deploy file with exists_only';
is_deeply +MockOutput->get_emit, [], 'Nothing should have been emitted';

ok $show->execute(revert => $change->id), 'Show a revert file';
is_deeply +MockOutput->get_emit, [[ $change->revert_file->slurp(iomode => '<:raw') ]],
    'The revert file should have been emitted';

# Nonexistent verify file.
throws_ok { $show->execute( verify => $change->id ) } 'App::Sqitch::X',
    'Should get error for nonexistent varify file';
is $@->ident, 'show', 'Nonexistent file error ident should be "show"';
is $@->message, __x('File "{path}" does not exist', path => $change->verify_file ),
    'Should get proper error for nonexistent file';

# Nonexistent with exists_only.
ok !$eshow->execute( verify => $change->id ),
    'Should return false for nonexistent file';
is_deeply +MockOutput->get_emit, [], 'Nothing should have been emitted';

# Now an unknown type.
throws_ok { $show->execute(foo => 'bar') } 'App::Sqitch::X',
    'Should get error for uknown type';
is $@->ident, 'show', 'Unknown type error ident should be "show"';
is $@->message,  __x(
    'Unknown object type "{type}',
    type => 'foo',
), 'Should get proper error for unknown type';

# Try specifying a non-default target.
$sqitch = App::Sqitch->new;
$sqitch->config->load_file(file 't', 'local.conf');
my $file = file qw(t plans dependencies.plan);
my $target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
ok $change = $target->plan->get('add_user'), 'Get a change';

# Set it up.
isa_ok $show = $CLASS->new(sqitch => $sqitch, target => 'mydb'), $CLASS;
is $show->target, 'mydb', 'Target should be set';
ok $show->execute( change => $change->id ), 'Find change by id';
is_deeply +MockOutput->get_emit, [[ $change->info ]],
    'The change info should have been emitted';

# Now try invalid args.
my $mock = Test::MockModule->new($CLASS);
my @usage;
$mock->mock(usage => sub { shift; @usage = @_; die 'USAGE' });
throws_ok { $show->execute } qr/USAGE/, 'Should get usage for missing params';
is_deeply \@usage, [], 'Nothing should have been passed to usage';

done_testing;
