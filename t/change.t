#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 49;
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
    $CLASS = 'App::Sqitch::Plan::Change';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    comment
    since_tag
    suffix
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
    uri     => URI->new('https://github.com/theory/sqitch/'),
    top_dir => dir('sql'),
);
my $plan  = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $change = $CLASS->new(
    name => 'foo',
    plan => $plan,
), $CLASS;

isa_ok $change, 'App::Sqitch::Plan::Line';
ok $change->is_deploy, 'It should be a deploy change';
ok !$change->is_revert, 'It should not be a revert change';
is $change->action, 'deploy', 'And it should say so';

is_deeply $change->_fn, ['foo.sql'], '_fn should have the file name';
is $change->deploy_file, $sqitch->deploy_dir->file('foo.sql'),
    'The deploy file should be correct';
is $change->revert_file, $sqitch->revert_dir->file('foo.sql'),
    'The revert file should be correct';
is $change->test_file, $sqitch->test_dir->file('foo.sql'),
    'The test file should be correct';

is $change->format_name, 'foo', 'Name should format as "foo"';
is $change->format_name_with_tags,
    'foo', 'Name should format with tags as "foo"';
is $change->as_string, 'foo', 'should stringify to "foo"';
is $change->since_tag, undef, 'Since tag should be undef';
is $change->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'change foo',
), 'Change info should be correct';
is $change->id, do {
    my $content = $change->info;
    Digest::SHA1->new->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Change ID should be correct';

my $tag = App::Sqitch::Plan::Tag->new(
    plan => $plan,
    name => 'alpha',
    change => $change,
);

ok my $change2 = $CLASS->new(
    name      => 'yo/howdy',
    plan      => $plan,
    since_tag => $tag,
    lspace    => '  ',
    operator  => '-',
    ropspace  => ' ',
    rspace    => "\t",
    suffix    => '@beta',
    comment   => ' blah blah blah',
    pspace    => '  ',
    requires  => [qw(foo bar @baz)],
    conflicts => ['dr_evil'],
), 'Create change with more stuff';

is $change2->as_string, "  - yo/howdy  :foo :bar :\@baz !dr_evil\t# blah blah blah",
    'It should stringify correctly';
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(index_of => 0);

ok !$change2->is_deploy, 'It should not be a deploy change';
ok $change2->is_revert, 'It should be a revert change';
is $change2->action, 'revert', 'It should say so';
is $change2->since_tag, $tag, 'It should have a since tag';
is $change2->info, join("\n",
   'project ' . $sqitch->uri->canonical,
   'change yo/howdy',
   'since ' . $tag->id,
), 'Info should include since tag';

# Check tags.
is_deeply [$change2->tags], [], 'Should have no tags';
ok $change2->add_tag($tag), 'Add a tag';
is_deeply [$change2->tags], [$tag], 'Should have the tag';
is $change2->format_name_with_tags, 'yo/howdy @alpha',
    'Should format name with tags';

# Check file names.
my @fn = ('yo', 'howdy@beta.sql');
is_deeply $change2->_fn, \@fn, '_fn should separate out directories';
is $change2->deploy_file, $sqitch->deploy_dir->file(@fn),
    'The deploy file should include the suffix';
is $change2->revert_file, $sqitch->revert_dir->file(@fn),
    'The revert file should include the suffix';
is $change2->test_file, $sqitch->test_dir->file(@fn),
    'The test file should include the suffix';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy))->stringify;
END { remove_tree 'sql' };
file(qw(sql deploy baz.sql))->touch;
my $change2_file = file qw(sql deploy bar.sql);
my $fh = $change2_file->open('>:utf8') or die "Cannot open $change2_file: $!\n";
$fh->say('-- This is a comment');
$fh->say('# And so is this');
$fh->say('; and this, w€€!');
$fh->say('/* blah blah blah */');
$fh->close;

ok $change2 = $CLASS->new( name => 'baz', plan => $plan ),
    'Create change "baz"';

ok $change2 = $CLASS->new( name => 'bar', plan => $plan ),
    'Create change "bar"';

##############################################################################
# Test file handles.
ok $fh = $change2->deploy_handle, 'Get deploy handle';
is $fh->getline, "-- This is a comment\n", 'It should be the deploy file';

make_path dir(qw(sql revert))->stringify;
$fh = $change2->revert_file->open('>')
    or die "Cannot open " . $change2->revert_file . ": $!\n";
$fh->say('-- revert it, baby');
$fh->close;
ok $fh = $change2->revert_handle, 'Get revert handle';
is $fh->getline, "-- revert it, baby\n", 'It should be the revert file';

make_path dir(qw(sql test))->stringify;
$fh = $change2->test_file->open('>')
    or die "Cannot open " . $change2->test_file . ": $!\n";
$fh->say('-- test it, baby');
$fh->close;
ok $fh = $change2->test_handle, 'Get test handle';
is $fh->getline, "-- test it, baby\n", 'It should be the test file';

##############################################################################
# Test the requires/conflicts params.
my $file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(
    uri       => URI->new('https://github.com/theory/sqitch/'),
    top_dir   => dir('sql'),
    plan_file => $file,
);
$plan = $sqitch->plan;
ok $change2 = $CLASS->new(
    name      => 'whatever',
    plan      => $plan,
    requires  => [qw(hey you)],
    conflicts => ['hey-there'],
), 'Create a change with explicit requires and conflicts';
is_deeply [$change2->requires], [qw(hey you)], 'requires should be set';
is_deeply [$change2->conflicts], ['hey-there'], 'conflicts should be set';
is_deeply [$change2->requires_changes], [$plan->get('hey'),  $plan->get('you')],
    'Should find changes for requires';
is_deeply [$change2->conflicts_changes], [$plan->get('hey-there')],
    'Should find changes for conflicts';

##############################################################################
# Test ID for a change with a UTF-8 name.
ok $change2 = $CLASS->new(
    name => '阱阪阬',
    plan => $plan,
), 'Create change with UTF-8 name';
is $change2->info, join("\n",
    'project ' . $sqitch->uri->canonical,
    'change '    . '阱阪阬'
), 'The name should be decoded text';

is $change2->id, do {
    my $content = Encode::encode_utf8 $change2->info;
    Digest::SHA1->new->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Change ID should be hahsed from encoded UTF-8';
