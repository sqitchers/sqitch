#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 39;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::tag';

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('test-tag_cmd'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $tag = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'tag',
    config  => $config,
}), $CLASS, 'tag command';

can_ok $CLASS, qw(
    options
    configure
    note
    execute
);

is_deeply [$CLASS->options], [qw(
    note|n|m=s@
)], 'Should have note option';

make_path 'test-tag_cmd';
END { remove_tree 'test-tag_cmd' };
my $plan_file = $sqitch->plan_file;
my $fh = $plan_file->open('>') or die "Cannot open $plan_file: $!";
say $fh "%project=empty\n\n";
$fh->close or die "Error closing $plan_file: $!";

# Override request_note().
my $tag_mocker = Test::MockModule->new('App::Sqitch::Plan::Tag');
my %request_params;
$tag_mocker->mock(request_note => sub {
    shift;
    %request_params = @_;
});

my $plan = $sqitch->plan;
ok $plan->add( name => 'foo' ), 'Add change "foo"';

ok $tag->execute('alpha'), 'Tag @alpha';
is $plan->get('@alpha')->name, 'foo', 'Should have tagged "foo"';
ok $plan->load, 'Reload plan';
is $plan->get('@alpha')->name, 'foo', 'New tag should have been written';
is [$plan->tags]->[-1]->note, '', 'New tag should have empty note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag}',
        change => 'foo',
        tag    => '@alpha',
    ]
], 'The info message should be correct';

# With no arg, should get a list of tags.
ok $tag->execute, 'Execute with no arg';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
], 'The one tag should have been listed';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

# Get a list of tags.
ok $plan->tag( name => '@beta' ), 'Add tag @beta';
ok $tag->execute, 'Execute with no arg again';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
    ['@beta'],
], 'Both tags should have been listed';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

# Set a note.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => [qw(hello there)],
}), $CLASS, 'tag command with note';

ok $tag->execute( 'gamma' ), 'Tag @gamma';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should be on change "foo"';
is [$plan->tags]->[-1]->note, "hello\n\nthere", 'Gamma tag should have note';
ok $plan->load, 'Reload plan';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should have been written';
is [$plan->tags]->[-1]->note, "hello\n\nthere", 'Written tag should have note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag}',
        change => 'foo',
        tag    => '@gamma',
    ]
], 'The gamma note should be correct';

# Tag a specific change.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => ['here we go'],
}), $CLASS, 'tag command with note';

ok $plan->add( name => 'bar' ), 'Add change "bar"';
ok $plan->add( name => 'baz' ), 'Add change "baz"';
ok $tag->execute('delta', 'bar'), 'Tag change "bar" with @delta';
is $plan->get('@delta')->name, 'bar', 'Should have tagged "bar"';
ok $plan->load, 'Reload plan';
is $plan->get('@delta')->name, 'bar', 'New tag should have been written';
is [$plan->tags]->[-1]->note, 'here we go', 'New tag should have the proper note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag}',
        change => 'bar',
        tag    => '@delta',
    ]
], 'The info message should be correct';
