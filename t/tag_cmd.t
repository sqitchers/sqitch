#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 59;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Path::Class qw(file dir);
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::tag';

my $dir = dir 'test-tag_cmd';
ok my $sqitch = App::Sqitch->new(
    options => {
        engine => 'sqlite',
        top_dir => $dir->stringify,
    },
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
    tag-name|tag|t=s
    change-name|change|c=s
    note|n|m=s@
)], 'Should have note option';

make_path $dir->stringify;
END { remove_tree $dir->stringify };
my $plan_file = $tag->default_target->plan_file;
$plan_file->spew("%project=empty\n\n");

# Override request_note().
my $tag_mocker = Test::MockModule->new('App::Sqitch::Plan::Tag');
my %request_params;
$tag_mocker->mock(request_note => sub {
    my $self = shift;
    %request_params = @_;
    $self->note;
});

my $plan = $tag->default_target->plan;
ok $plan->add( name => 'foo' ), 'Add change "foo"';

ok $tag->execute('alpha'), 'Tag @alpha';
is $plan->get('@alpha')->name, 'foo', 'Should have tagged "foo"';
ok $plan->load, 'Reload plan';
is $plan->get('@alpha')->name, 'foo', 'New tag should have been written';
is [$plan->tags]->[-1]->note, '', 'New tag should have empty note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'foo',
        tag    => '@alpha',
        file   => $plan->file,
    ]
], 'The info message should be correct';

# With no arg, should get a list of tags.
ok $tag->execute, 'Execute with no arg';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
], 'The one tag should have been listed';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

# Add a tag.
ok $plan->tag( name => '@beta' ), 'Add tag @beta';
ok $tag->execute, 'Execute with no arg again';
is_deeply +MockOutput->get_info, [
    ['@alpha'],
    ['@beta'],
], 'Both tags should have been listed';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

# Set a note and a name.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => [qw(hello there)],
    tag_name => 'gamma',
}), $CLASS, 'tag command with note';
$plan = $tag->default_target->plan;

ok $tag->execute, 'Tag @gamma';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should be on change "foo"';
is [$plan->tags]->[-1]->note, "hello\n\nthere", 'Gamma tag should have note';
ok $plan->load, 'Reload plan';
is $plan->get('@gamma')->name, 'foo', 'Gamma tag should have been written';
is [$plan->tags]->[-1]->note, "hello\n\nthere", 'Written tag should have note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'foo',
        tag    => '@gamma',
        file   => $plan->file,
    ]
], 'The gamma note should be correct';

# Tag a specific change.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => ['here we go'],
}), $CLASS, 'tag command with note';
$plan = $tag->default_target->plan;

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
        'Tagged "{change}" with {tag} in {file}',
        change => 'bar',
        tag    => '@delta',
        file   => $plan->file,
    ]
], 'The info message should be correct';

# Use --change to tage a specific change.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch      => $sqitch,
    change_name => 'bar',
    note        => ['here we go'],
}), $CLASS, 'tag command with change name';
$plan = $tag->default_target->plan;

ok $tag->execute('zeta', 'bar'), 'Tag change "bar" with @zeta';
is $plan->get('@zeta')->name, 'bar', 'Should have tagged "bar" with @zeta';
ok $plan->load, 'Reload plan';
is $plan->get('@zeta')->name, 'bar', 'Tag @zeta should have been written';
is [$plan->tags]->[-1]->note, 'here we go', 'Tag @zeta should have the proper note';
is_deeply \%request_params, { for => __ 'tag' }, 'Should have requested a note';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'bar',
        tag    => '@zeta',
        file   => $plan->file,
    ]
], 'The zeta info message should be correct';

##############################################################################
# Let's deal with multiple engines.
my $conf = $dir->file('sqitch.conf');
$conf->spew(join "\n",
    '[core]',
    'engine = pg',
    '[engine "pg"]',
    'top_dir = pg',
    '[engine "sqlite"]',
    'top_dir = sqlite',
    '[engine "mysql"]',
    'top_dir = mysql',
);

local $ENV{SQITCH_CONFIG} = $conf->stringify;
ok $sqitch = App::Sqitch->new(
    options => {
        engine => 'sqlite',
        top_dir => $dir->stringify,
    },
), 'Load another sqitch sqitch object';

isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => ['here we go again'],
}), $CLASS, 'another tag command';
$plan = $tag->default_target->plan;
ok $tag->execute('whacko'), 'Tag with @whacko';
is $plan->get('@whacko')->name, 'baz', 'Should have tagged "baz" with @whacko';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'baz',
        tag    => '@whacko',
        file   => $plan->file,
    ]
], 'The whacko info message should be correct';

# Great. Now try two plans!
my $pg = $dir->file('pg.plan');
my $sqlite = $dir->file('sqlite.plan');
$conf->spew(join "\n",
    '[core]',
    'engine = pg',
    "top_dir = $dir",
    '[engine "pg"]',
    "plan_file = $pg",
    '[engine "sqlite"]',
    "plan_file = $sqlite",
);

$dir->file("$_.plan")->spew(
    "%project=tag\n\n${_}_change 2012-07-16T17:25:07Z Hi <hi\@foo.com>\n"
) for qw(pg sqlite);

ok $sqitch = App::Sqitch->new,
    'Load another sqitch sqitch object';

isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => ['here we go again'],
}), $CLASS, 'yet another tag command';
ok $tag->execute('dubdub'), 'Tag with @dubdub';
my @targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
is @targets, 2, 'Should have two targets';
is $targets[0]->plan->get('@dubdub')->name, 'pg_change',
    'Should have tagged pg plan change "pg_change" with @dubdub';
is $targets[1]->plan->get('@dubdub')->name, 'sqlite_change',
    'Should have tagged sqlite plan change "sqlite_change" with @dubdub';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'pg_change',
        tag    => '@dubdub',
        file   => $targets[0]->plan_file,
    ],
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'sqlite_change',
        tag    => '@dubdub',
        file   => $targets[1]->plan_file,
    ],
], 'The dubdub info message should show both plans tagged';
