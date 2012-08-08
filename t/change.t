#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 66;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use App::Sqitch::Plan::Tag;
use Locale::TextDomain qw(App-Sqitch);
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

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

can_ok $CLASS, qw(
    name
    lspace
    rspace
    note
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
    timestamp
    planner_name
    planner_email
    format_name
    format_dependencies
    format_name_with_tags
    format_name_with_dependencies
    format_op_name_dependencies
    format_planner
    note_prompt
);

my $sqitch = App::Sqitch->new( top_dir => dir('sql') );
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
make_path 'sql';
END { remove_tree 'sql' };
my $fn = $sqitch->plan_file;
open my $fh, '>', $fn or die "Cannot open $fn: $!";
say $fh '%project=change';
close $fh or die "Error closing $fn: $!";

isa_ok my $change = $CLASS->new(
    name => 'foo',
    plan => $plan,
), $CLASS;

isa_ok $change, 'App::Sqitch::Plan::Line';
ok $change->is_deploy, 'It should be a deploy change';
ok !$change->is_revert, 'It should not be a revert change';
is $change->action, 'deploy', 'And it should say so';
isa_ok $change->timestamp, 'App::Sqitch::DateTime', 'Timestamp';

is_deeply $change->_fn, ['foo.sql'], '_fn should have the file name';
is $change->deploy_file, $sqitch->deploy_dir->file('foo.sql'),
    'The deploy file should be correct';
is $change->revert_file, $sqitch->revert_dir->file('foo.sql'),
    'The revert file should be correct';
is $change->test_file, $sqitch->test_dir->file('foo.sql'),
    'The test file should be correct';
ok $change->suffix('@foo'), 'Set the suffix';
is_deeply $change->_fn, ['foo@foo.sql'], '_fn should now include suffix';

is $change->format_name, 'foo', 'Name should format as "foo"';
is $change->format_name_with_tags,
    'foo', 'Name should format with tags as "foo"';
is $change->format_dependencies, '', 'Dependencies should format as ""';
is $change->format_name_with_dependencies, 'foo',
    'Name should format with dependencies as "foo"';
is $change->format_op_name_dependencies, 'foo',
    'Name should format op without dependencies as "foo"';
is $change->format_content, 'foo ' . $change->timestamp->as_string
    . ' ' . $change->format_planner,
    'Change content should format correctly without dependencies';

is $change->planner_name, $sqitch->user_name,
    'Planner name shoudld default to user name';
is $change->planner_email, $sqitch->user_email,
    'Planner email shoudld default to user email';
is $change->format_planner, join(
    ' ',
    $sqitch->user_name,
    '<' . $sqitch->user_email . '>'
), 'Planner name and email should format properly';

my $ts = $change->timestamp->as_string;
is $change->as_string, "foo $ts " . $change->format_planner,
    'should stringify to "foo" + planner';
is $change->since_tag, undef, 'Since tag should be undef';
is $change->info, join("\n",
   'project change',
   'change foo',
   'planner ' . $change->format_planner,
   'date ' . $change->timestamp->as_string,
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

my $date = App::Sqitch::DateTime->new(
    year   => 2012,
    month  => 7,
    day    => 16,
    hour   => 17,
    minute => 25,
    second => 7,
    time_zone => 'UTC',
);

sub dep($) { App::Sqitch::Plan::Depend->parse(shift) }

ok my $change2 = $CLASS->new(
    name      => 'yo/howdy',
    plan      => $plan,
    since_tag => $tag,
    lspace    => '  ',
    operator  => '-',
    ropspace  => ' ',
    rspace    => "\t",
    suffix    => '@beta',
    note      => 'blah blah blah',
    pspace    => '  ',
    requires  => [map { dep $_ } qw(foo bar @baz)],
    conflicts => [dep '!dr_evil'],
    timestamp     => $date,
    planner_name  => 'Barack Obama',
    planner_email => 'potus@whitehouse.gov',
), 'Create change with more stuff';

my $ts2 = '2012-07-16T17:25:07Z';
is $change2->as_string, "  - yo/howdy  [foo bar \@baz !dr_evil] "
    . "$ts2 Barack Obama <potus\@whitehouse.gov>\t# blah blah blah",
    'It should stringify correctly';
my $mock_plan = Test::MockModule->new(ref $plan);
$mock_plan->mock(index_of => 0);
my $uri = URI->new('https://github.com/theory/sqitch/');
$mock_plan->mock( uri => $uri );

ok !$change2->is_deploy, 'It should not be a deploy change';
ok $change2->is_revert, 'It should be a revert change';
is $change2->action, 'revert', 'It should say so';
is $change2->since_tag, $tag, 'It should have a since tag';
is $change2->info, join("\n",
   'project change',
   'uri https://github.com/theory/sqitch/',
   'change yo/howdy',
   'planner Barack Obama <potus@whitehouse.gov>',
   'date 2012-07-16T17:25:07Z'
), 'Info should include since tag';

# Check tags.
is_deeply [$change2->tags], [], 'Should have no tags';
ok $change2->add_tag($tag), 'Add a tag';
is_deeply [$change2->tags], [$tag], 'Should have the tag';
is $change2->format_name_with_tags, 'yo/howdy @alpha',
    'Should format name with tags';
is $change2->format_planner, 'Barack Obama <potus@whitehouse.gov>',
    'Planner name and email should format properly';
is $change2->format_dependencies, '[foo bar @baz !dr_evil]',
    'Dependencies should format as "[foo bar @baz !dr_evil]"';
is $change2->format_name_with_dependencies, 'yo/howdy  [foo bar @baz !dr_evil]',
    'Name should format with dependencies as "yo/howdy  [foo bar @baz !dr_evil]"';
is $change2->format_op_name_dependencies, '- yo/howdy  [foo bar @baz !dr_evil]',
    'Name should format op with dependencies as "yo/howdy  [foo bar @baz !dr_evil]"';
is $change2->format_content, '- yo/howdy  [foo bar @baz !dr_evil] '
    . $change2->timestamp->as_string . ' ' . $change2->format_planner,
    'Change content should format correctly with dependencies';

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
file(qw(sql deploy baz.sql))->touch;
my $change2_file = file qw(sql deploy bar.sql);
$fh = $change2_file->open('>:utf8') or die "Cannot open $change2_file: $!\n";
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
my $sqitch2 = App::Sqitch->new(
    top_dir   => dir('sql'),
    plan_file => $file,
);
my $plan2 = $sqitch2->plan;
ok $change2 = $CLASS->new(
    name      => 'whatever',
    plan      => $plan2,
    requires  => [dep 'hey', dep 'you'],
    conflicts => [dep '!hey-there'],
), 'Create a change with explicit requires and conflicts';
is_deeply [$change2->requires], [dep 'hey', dep 'you'], 'requires should be set';
is_deeply [$change2->conflicts], [dep '!hey-there'], 'conflicts should be set';
is_deeply [$change2->requires_changes], [$plan2->get('hey'),  $plan2->get('you')],
    'Should find changes for requires';
is_deeply [$change2->conflicts_changes], [$plan2->get('hey-there')],
    'Should find changes for conflicts';

##############################################################################
# Test ID for a change with a UTF-8 name.
ok $change2 = $CLASS->new(
    name => '阱阪阬',
    plan => $plan2,
), 'Create change with UTF-8 name';
is $change2->info, join("\n",
    'project ' . 'multi',
    'uri '     . $uri->canonical,
    'change '  . '阱阪阬',
    'planner ' . $change2->format_planner,
    'date '    . $change2->timestamp->as_string,
), 'The name should be decoded text';

is $change2->id, do {
    my $content = Encode::encode_utf8 $change2->info;
    Digest::SHA1->new->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Change ID should be hahsed from encoded UTF-8';

##############################################################################
# Test note_prompt().
is $change->note_prompt(
    for => 'add',
    scripts => [$change->deploy_file, $change->revert_file, $change->test_file],
), exp_prompt(
    for => 'add',
    scripts => [$change->deploy_file, $change->revert_file, $change->test_file],
    name    => $change->format_op_name_dependencies,
), 'note_prompt() should work';

is $change2->note_prompt(
    for => 'add',
    scripts => [$change2->deploy_file, $change2->revert_file, $change2->test_file],
), exp_prompt(
    for => 'add',
    scripts => [$change2->deploy_file, $change2->revert_file, $change2->test_file],
    name    => $change2->format_op_name_dependencies,
), 'note_prompt() should work';

sub exp_prompt {
    my %p = @_;
    join(
        '',
        __x(
            "Please enter a note for your change. Lines starting with '#' will\n" .
            "be ignored, and an empty message aborts the {command}.",
            command => $p{for},
        ),
        $/,
        __x('Change to {command}:', command => $p{for}),
        $/, $/,
        '  ', $p{name},
        join "$/    ", '', @{ $p{scripts} },
        $/,
    );
}
