#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 56;
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
    is_duped
    tags
    add_tag
    plan
    deploy_file
    revert_file
    test_file
    requires
    conflicts
    format_name
    format_name_with_tags
);

my $sqitch = App::Sqitch->new(
    uri => URI->new('https://github.com/theory/sqitch/'),
);
my $plan  = App::Sqitch::Plan->new(sqitch => $sqitch);
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(index_of => 0);

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
is $step->format_name_with_tags,
    'foo', 'Name should format with tags as "foo"';
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

ok my $step2 = $CLASS->new(
    name      => 'howdy',
    plan      => $plan,
    since_tag => $tag,
    lspace    => '  ',
    operator  => '-',
    ropspace  => ' ',
    rspace    => "\t",
    is_duped  => 1,
    comment   => ' blah blah blah',
), 'Create step with more stuff';

is $step2->as_string, "  - howdy\t# blah blah blah",
    'It should stringify correctly';

ok !$step2->is_deploy, 'It should not be a deploy step';
ok $step2->is_revert, 'It should be a revert step';
is $step2->action, 'revert', 'It should say so';
is $step2->since_tag, $tag, 'It should have a since tag';
is $step2->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'step howdy',
   'since ' . $tag->id,
), 'Info should include since tag';

# Check tags.
is_deeply [$step2->tags], [], 'Should have no tags';
ok $step2->add_tag($tag), 'Add a tag';
is_deeply [$step2->tags], [$tag], 'Should have the tag';
is $step2->format_name_with_tags, 'howdy @alpha',
    'Should format name with tags';

# Check file names.
is $step2->deploy_file, $sqitch->deploy_dir->file('howdy@alpha.sql'),
    'The deploy file should ref the since tag';
is $step2->revert_file, $sqitch->revert_dir->file('howdy@alpha.sql'),
    'The revert file should ref the since tag';
is $step2->test_file, $sqitch->test_dir->file('howdy@alpha.sql'),
    'The test file should ref the since tag';

# Try it with the implicit @ROOT tag by making it the second step in the plan.
my $step3 = $CLASS->new(
    name => 'woot',
    plan => $plan,
);
$mock_plan->mock(_root_step => $step);
is $step3->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'step woot',
   'since ' . App::Sqitch::Plan::Tag->new(
       plan => $plan,
       step => $step,
       name => 'ROOT',
   )->id
), 'Step info since @ROOT should be correct';
is $step3->id, do {
    my $content = $step3->info;
    Digest::SHA1->new->add(
        'step ' . length($content) . "\0" . $content
    )->hexdigest;
},'Step ID since @ROOT should be correct';
$mock_plan->unmock('_root_step');

##############################################################################
# Test _parse_dependencies.
can_ok $CLASS, '_parse_dependencies';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy))->stringify;
END { remove_tree 'sql' };
file(qw(sql deploy baz.sql))->touch;
my $step2_file = file qw(sql deploy bar.sql);
my $fh = $step2_file->open('>:utf8') or die "Cannot open $step2_file: $!\n";
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

ok $step2 = $CLASS->new( name => 'baz', plan => $plan ),
    'Create step "baz"';
is_deeply $step2->_parse_dependencies, { conflicts => [], requires => [] },
    'baz.sql should have no dependencies';
is_deeply [$step2->requires], [], 'Requires should be empty';
is_deeply [$step2->conflicts], [], 'Conflicts should be empty';

ok $step2 = $CLASS->new( name => 'bar', plan => $plan ),
    'Create step "bar"';
is_deeply $step2->_parse_dependencies([], 'bar'), {
    requires  => [qw(foo foo @yo blah blah w00t)],
    conflicts => [qw(yak this that)],
},  'bar.sql should have a bunch of dependencies';
is_deeply [$step2->requires], [qw(foo foo @yo blah blah w00t)],
    'Requires get filled in';
is_deeply [$step2->conflicts], [qw(yak this that)], 'Conflicts get filled in';

##############################################################################
# Test file handles.
ok $fh = $step2->deploy_handle, 'Get deploy handle';
is $fh->getline, "-- This is a comment\n", 'It should be the deploy file';

make_path dir(qw(sql revert))->stringify;
$fh = $step2->revert_file->open('>')
    or die "Cannot open " . $step2->revert_file . ": $!\n";
$fh->say('-- revert it, baby');
$fh->close;
ok $fh = $step2->revert_handle, 'Get revert handle';
is $fh->getline, "-- revert it, baby\n", 'It should be the revert file';

make_path dir(qw(sql test))->stringify;
$fh = $step2->test_file->open('>')
    or die "Cannot open " . $step2->test_file . ": $!\n";
$fh->say('-- test it, baby');
$fh->close;
ok $fh = $step2->test_handle, 'Get test handle';
is $fh->getline, "-- test it, baby\n", 'It should be the test file';

##############################################################################
# Test the requires/conflicts params.
ok $step2 = $CLASS->new(
    name      => 'whatever',
    plan      => $plan,
    requires  => [qw(hi there)],
    conflicts => [],
), 'Create a step with explicit requires and conflicts';
is_deeply [$step2->requires], [qw(hi there)], 'requires should be set';
is_deeply [$step2->conflicts], [], 'conflicts should be set';

# Make sure that conflicts and requires are mutually requried.
throws_ok { $CLASS->new( requires => [] ) }
    qr/\QThe "conflicts" and "requires" parameters must both be required or omitted/,
    'Should get an error for requires but no conflicts';

throws_ok { $CLASS->new( conflicts => [] ) }
    qr/\QThe "conflicts" and "requires" parameters must both be required or omitted/,
    'Should get an error for conflicts but no requires';

##############################################################################
# Test ID for a step with a UTF-8 name.
ok $step2 = $CLASS->new(
    name => '阱阪阬',
    plan => $plan,
), 'Create step with UTF-8 name';
is $step2->info, join("\n",
    'project ' . $sqitch->uri->canonical,
    'step '    . '阱阪阬'
), 'The name should be decoded text';

is $step2->id, do {
    my $content = Encode::encode_utf8 $step2->info;
    Digest::SHA1->new->add(
        'step ' . length($content) . "\0" . $content
    )->hexdigest;
},'Step ID should be hahsed from encoded UTF-8';
