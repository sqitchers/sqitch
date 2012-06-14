#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 43;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use App::Sqitch::Plan::Tag;
use Test::Exception;
use Path::Class;
use File::Path qw(make_path remove_tree);
use Digest::SHA1;
use Test::MockModule;
use URI;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Step';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    comment
    since_tag
    plan
    deploy_file
    revert_file
    test_file
    requires
    conflicts
);

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
my $plan  = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $step = $CLASS->new(
    name => 'foo',
    plan => $plan,
), $CLASS;

isa_ok $step, 'App::Sqitch::Plan::Line';
ok $step->is_deploy, 'It should be a deploy step';
ok !$step->is_revert, 'It should not be a revert step';
is $step->action, 'deploy', 'And it should say so';

is $step->deploy_file, $sqitch->deploy_dir->file('foo.sql'),
    'The deploy file should be correct';
is $step->revert_file, $sqitch->revert_dir->file('foo.sql'),
    'The revert file should be correct';
is $step->test_file, $sqitch->test_dir->file('foo.sql'),
    'The test file should be correct';

is $step->format_name, 'foo', 'Name should format as "foo"';
is $step->as_string, 'foo', 'should stringify to "foo"';
is $step->since_tag, undef, 'Since tag should be undef';
is $step->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'step foo',
), 'Step info should be correct';
is $step->id, do {
    my $content = $step->info;
    Digest::SHA1->new->add(
        'step ' . length($content) . "\0" . $content
    )->hexdigest;
},'Step ID should be correct';

my $tag = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    name => 'alpha',
    step => $step,
);

ok $step = $CLASS->new(
    name      => 'howdy',
    plan      => $plan,
    since_tag => $tag,
    lspace    => '  ',
    operator  => '-',
    ropspace  => ' ',
    rspace    => "\t",
    comment   => ' blah blah blah',
), 'Create step with more stuff';

is $step->as_string, "  - howdy\t# blah blah blah",
    'It should stringify correctly';
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(index_of => 0);

ok !$step->is_deploy, 'It should not be a deploy step';
ok $step->is_revert, 'It should be a revert step';
is $step->action, 'revert', 'It should say so';
is $step->since_tag, $tag, 'It should have a since tag';
is $step->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'step howdy',
   'since ' . $tag->id,
), 'Info should include since tag';

##############################################################################
# Test _parse_dependencies.
can_ok $CLASS, '_parse_dependencies';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy))->stringify;
END { remove_tree 'sql' };
file(qw(sql deploy baz.sql))->touch;
my $step_file = file qw(sql deploy bar.sql);
my $fh = $step_file->open('>:utf8') or die "Cannot open $step_file: $!\n";
$fh->say('-- This is a comment');
$fh->say('# And so is this');
$fh->say('; and this, w€€!');
$fh->say('/* blah blah blah */');
$fh->say('-- :requires: foo');
$fh->say('-- :requires: foo');
$fh->say('-- :requires: @yo');
$fh->say('-- :requires:blah blah w00t');
$fh->say('-- :conflicts: yak');
$fh->say('-- :conflicts:this that');
$fh->close;

ok $step = $CLASS->new( name => 'baz', plan => $plan ),
    'Create step "baz"';
is_deeply $step->_parse_dependencies, { conflicts => [], requires => [] },
    'baz.sql should have no dependencies';
is_deeply [$step->requires], [], 'Requires should be empty';
is_deeply [$step->conflicts], [], 'Conflicts should be empty';

ok $step = $CLASS->new( name => 'bar', plan => $plan ),
    'Create step "bar"';
is_deeply $step->_parse_dependencies([], 'bar'), {
    requires  => [qw(foo foo @yo blah blah w00t)],
    conflicts => [qw(yak this that)],
},  'bar.sql should have a bunch of dependencies';
is_deeply [$step->requires], [qw(foo foo @yo blah blah w00t)],
    'Requires get filled in';
is_deeply [$step->conflicts], [qw(yak this that)], 'Conflicts get filled in';

##############################################################################
# Test file handles.
ok $fh = $step->deploy_handle, 'Get deploy handle';
is $fh->getline, "-- This is a comment\n", 'It should be the deploy file';

make_path dir(qw(sql revert))->stringify;
$fh = $step->revert_file->open('>')
    or die "Cannot open " . $step->revert_file . ": $!\n";
$fh->say('-- revert it, baby');
$fh->close;
ok $fh = $step->revert_handle, 'Get revert handle';
is $fh->getline, "-- revert it, baby\n", 'It should be the revert file';

make_path dir(qw(sql test))->stringify;
$fh = $step->test_file->open('>')
    or die "Cannot open " . $step->test_file . ": $!\n";
$fh->say('-- test it, baby');
$fh->close;
ok $fh = $step->test_handle, 'Get test handle';
is $fh->getline, "-- test it, baby\n", 'It should be the test file';

##############################################################################
# Test the requires/conflicts params.
ok $step = $CLASS->new(
    name      => 'whatever',
    plan      => $plan,
    requires  => [qw(hi there)],
    conflicts => [],
), 'Create a step with explicit requires and conflicts';
is_deeply [$step->requires], [qw(hi there)], 'requires should be set';
is_deeply [$step->conflicts], [], 'conflicts should be set';

# Make sure that conflicts and requires are mutually requried.
throws_ok { $CLASS->new( requires => [] ) }
    qr/\QThe "conflicts" and "requires" parameters must both be required or omitted/,
    'Should get an error for requires but no conflicts';

throws_ok { $CLASS->new( conflicts => [] ) }
    qr/\QThe "conflicts" and "requires" parameters must both be required or omitted/,
    'Should get an error for conflicts but no requires';
