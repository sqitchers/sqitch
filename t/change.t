#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 87;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Target;
use App::Sqitch::Plan;
use App::Sqitch::Plan::Tag;
use Encode qw(encode_utf8);
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Path::Class;
use File::Path qw(make_path remove_tree);
use Digest::SHA;
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
    info
    id
    old_info
    old_id
    lspace
    rspace
    note
    parent
    since_tag
    rework_tags
    add_rework_tags
    is_reworked
    tags
    add_tag
    plan
    deploy_file
    script_hash
    revert_file
    verify_file
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

my $sqitch = App::Sqitch->new( options => {
    engine => 'sqlite',
    top_dir => dir('test-change')->stringify,
});
my $target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    reworked_dir => dir('reworked'),
);
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target);
make_path 'test-change';
END { remove_tree 'test-change' };
my $fn = $target->plan_file;
open my $fh, '>', $fn or die "Cannot open $fn: $!";
say $fh "%project=change\n\n";
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

my $tag = App::Sqitch::Plan::Tag->new(
    plan   => $plan,
    name   => 'alpha',
    change => $change,
);

is_deeply [ $change->path_segments ], ['foo.sql'],
    'path_segments should have the file name';
is $change->deploy_file, $target->deploy_dir->file('foo.sql'),
    'The deploy file should be correct';
is $change->revert_file, $target->revert_dir->file('foo.sql'),
    'The revert file should be correct';
is $change->verify_file, $target->verify_dir->file('foo.sql'),
    'The verify file should be correct';
ok !$change->is_reworked, 'The change should not be reworked';
is_deeply [ $change->path_segments ], ['foo.sql'],
    'path_segments should not include suffix';

# Test script_hash.
is $change->script_hash, undef,
    'Nonexistent deploy script hash should be undef';
make_path $change->deploy_file->dir->stringify;
$change->deploy_file->spew(iomode => '>:raw', encode_utf8 "Foo\nBar\nBøz\n亜唖娃阿" );
$change = $CLASS->new( name => 'foo', plan => $plan );
is $change->script_hash, 'd48866b846300912570f643c99b2ceec4ba29f5c',
    'Deploy script hash should be correct';

# Identify it as reworked.
ok $change->add_rework_tags($tag), 'Add a rework tag';
is_deeply [$change->rework_tags], [$tag], 'Reworked tag should be stored';
ok $change->is_reworked, 'The change should be reworked';
$target->deploy_dir->mkpath;
$target->deploy_dir->file('foo@alpha.sql')->touch;
is_deeply [ $change->path_segments ], ['foo@alpha.sql'],
    'path_segments should now include suffix';

# Make sure all rework tags are searched.
$change->clear_rework_tags;
ok !$change->is_reworked, 'The change should not be reworked';

my $tag2 = App::Sqitch::Plan::Tag->new(
    plan   => $plan,
    name   => 'beta',
    change => $change,
);
ok $change->add_rework_tags($tag2, $tag), 'Add two rework tags';
ok $change->is_reworked, 'The change should again be reworked';
is_deeply [ $change->path_segments ], ['foo@alpha.sql'],
    'path_segments should now include the correct suffixc';

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
is $change->parent, undef, 'Parent should be undef';
is $change->old_info, join("\n",
   'project change',
   'change foo',
   'planner ' . $change->format_planner,
   'date ' . $change->timestamp->as_string,
), 'Old change info should be correct';
is $change->old_id, do {
    my $content = encode_utf8 $change->old_info;
    Digest::SHA->new(1)->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Old change ID should be correct';

is $change->info, join("\n",
   'project change',
   'change foo',
   'planner ' . $change->format_planner,
   'date ' . $change->timestamp->as_string,
), 'Change info should be correct';
is $change->id, do {
    my $content = encode_utf8 $change->info;
    Digest::SHA->new(1)->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Change ID should be correct';

my $date = App::Sqitch::DateTime->new(
    year   => 2012,
    month  => 7,
    day    => 16,
    hour   => 17,
    minute => 25,
    second => 7,
    time_zone => 'UTC',
);

sub dep($) {
    App::Sqitch::Plan::Depend->new(
        %{ App::Sqitch::Plan::Depend->parse(shift) },
        plan    => $target->plan,
        project => 'change',
    )
}

ok my $change2 = $CLASS->new(
    name      => 'yo/howdy',
    plan      => $plan,
    since_tag => $tag,
    parent    => $change,
    lspace    => '  ',
    operator  => '-',
    ropspace  => ' ',
    rspace    => "\t",
    suffix    => '@beta',
    note      => 'blah blah blah ',
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
is $change2->parent, $change, 'It should have a parent';
is $change2->old_info, join("\n",
   'project change',
   'uri https://github.com/theory/sqitch/',
   'change yo/howdy',
   'planner Barack Obama <potus@whitehouse.gov>',
   'date 2012-07-16T17:25:07Z'
), 'Old info should not since tag';

is $change2->info, join("\n",
   'project change',
   'uri https://github.com/theory/sqitch/',
   'change yo/howdy',
   'parent ' . $change->id,
   'planner Barack Obama <potus@whitehouse.gov>',
   'date 2012-07-16T17:25:07Z',
   'requires',
   '  + foo',
   '  + bar',
   '  + @baz',
   'conflicts',
   '  - dr_evil',
   '', 'blah blah blah'
), 'Info should include parent and dependencies';

# Check tags.
is_deeply [$change2->tags], [], 'Should have no tags';
ok $change2->add_tag($tag), 'Add a tag';
is_deeply [$change2->tags], [$tag], 'Should have the tag';
is $change2->format_name_with_tags, 'yo/howdy @alpha',
    'Should format name with tags';

# Add another tag.
ok $change2->add_tag($tag2), 'Add another tag';
is_deeply [$change2->tags], [$tag, $tag2], 'Should have both tags';
is $change2->format_name_with_tags, 'yo/howdy @alpha @beta',
    'Should format name with both tags';

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
$change2->add_rework_tags($tag2);
is_deeply [ $change2->path_segments ], \@fn,
    'path_segments should include directories';
is $change2->deploy_file, $target->reworked_deploy_dir->file(@fn),
    'Deploy file should be in rworked dir and include suffix';
is $change2->revert_file, $target->reworked_revert_dir->file(@fn),
    'Revert file should be in rworked dir and include suffix';
is $change2->verify_file, $target->reworked_verify_dir->file(@fn),
    'Verify file should be in rworked dir and include suffix';

##############################################################################
# Test open_script.
make_path dir(qw(test-change deploy))->stringify;
file(qw(test-change deploy baz.sql))->touch;
my $change2_file = file qw(test-change deploy bar.sql);
$fh = $change2_file->open('>:utf8_strict') or die "Cannot open $change2_file: $!\n";
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

make_path dir(qw(test-change revert))->stringify;
$fh = $change2->revert_file->open('>')
    or die "Cannot open " . $change2->revert_file . ": $!\n";
$fh->say('-- revert it, baby');
$fh->close;
ok $fh = $change2->revert_handle, 'Get revert handle';
is $fh->getline, "-- revert it, baby\n", 'It should be the revert file';

make_path dir(qw(test-change verify))->stringify;
$fh = $change2->verify_file->open('>')
    or die "Cannot open " . $change2->verify_file . ": $!\n";
$fh->say('-- verify it, baby');
$fh->close;
ok $fh = $change2->verify_handle, 'Get verify handle';
is $fh->getline, "-- verify it, baby\n", 'It should be the verify file';

##############################################################################
# Test the requires/conflicts params.
my $file = file qw(t plans multi.plan);
my $sqitch2 = App::Sqitch->new(options => {
    engine    => 'sqlite',
    top_dir   => dir('test-change')->stringify,
    plan_file => $file->stringify,
});
my $target2 = App::Sqitch::Target->new(sqitch => $sqitch2);
my $plan2 = $target2->plan;
ok $change2 = $CLASS->new(
    name      => 'whatever',
    plan      => $plan2,
    requires  => [dep 'hey', dep 'you'],
    conflicts => [dep '!hey-there'],
), 'Create a change with explicit requires and conflicts';
is_deeply [$change2->requires], [dep 'hey', dep 'you'], 'requires should be set';
is_deeply [$change2->conflicts], [dep '!hey-there'], 'conflicts should be set';
is_deeply [$change2->dependencies], [dep 'hey', dep 'you', dep '!hey-there'],
    'Dependencies should include requires and conflicts';
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
is $change2->old_info, join("\n",
    'project ' . 'multi',
    'uri '     . $uri->canonical,
    'change '  . '阱阪阬',
    'planner ' . $change2->format_planner,
    'date '    . $change2->timestamp->as_string,
), 'The name should be decoded text in old info';

is $change2->old_id, do {
    my $content = Encode::encode_utf8 $change2->old_info;
    Digest::SHA->new(1)->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Old change ID should be hashed from encoded UTF-8';

is $change2->info, join("\n",
    'project ' . 'multi',
    'uri '     . $uri->canonical,
    'change '  . '阱阪阬',
    'planner ' . $change2->format_planner,
    'date '    . $change2->timestamp->as_string,
), 'The name should be decoded text in info';

is $change2->id, do {
    my $content = Encode::encode_utf8 $change2->info;
    Digest::SHA->new(1)->add(
        'change ' . length($content) . "\0" . $content
    )->hexdigest;
},'Change ID should be hashed from encoded UTF-8';

##############################################################################
# Test note_prompt().
is $change->note_prompt(
    for => 'add',
    scripts => [$change->deploy_file, $change->revert_file, $change->verify_file],
), exp_prompt(
    for => 'add',
    scripts => [$change->deploy_file, $change->revert_file, $change->verify_file],
    name    => $change->format_op_name_dependencies,
), 'note_prompt() should work';

is $change2->note_prompt(
    for => 'add',
    scripts => [$change2->deploy_file, $change2->revert_file, $change2->verify_file],
), exp_prompt(
    for => 'add',
    scripts => [$change2->deploy_file, $change2->revert_file, $change2->verify_file],
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
        "\n",
        __x('Change to {command}:', command => $p{for}),
        "\n\n",
        '  ', $p{name},
        join "\n    ", '', @{ $p{scripts} },
        "\n",
    );
}
