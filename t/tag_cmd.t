#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 78;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
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
ok !$tag->all, 'The all attribute should be false by default';

can_ok $CLASS, qw(
    options
    configure
    note
    execute
);

is_deeply [$CLASS->options], [qw(
    tag-name|tag|t=s
    change-name|change|c=s
    all|a!
    note|n|m=s@
)], 'Should have note option';

##############################################################################
# Test configure().
my $cmock = Test::MockModule->new('App::Sqitch::Config');
my (@vals, @params);
$cmock->mock( get => sub { shift; push @params, \@_; shift @vals } );

is_deeply $CLASS->configure($config, {}), {},
    'Should get empty hash for no config or options';
is_deeply \@params, [], 'Should not have fetched boolean tag.all config';
@params = ();
is_deeply $CLASS->configure(
    $config,
    { tag_name => 'foo', change_name => 'bar', all => 1}
),
    { tag_name => 'foo', change_name => 'bar', all => 1 },
    'Should get populated hash for no all options';

is_deeply \@params, [], 'Should not have fetched boolean tag.all config';
@params = ();

$cmock->unmock_all;

##############################################################################
# Test tagging a single plan.
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
    all    => 1,
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

# With --all and args, should get an error.
throws_ok { $tag->execute('fred', 'pg') } 'App::Sqitch::X',
    'Should get an error for --all and a target arg';
is $@->ident, 'tag', 'Mixed arguments error ident should be "tag"';
is $@->message, __(
    'Cannot specify both --all and engine, target, or plan arugments'
), 'Mixed arguments error message should be correct';

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

# Mock getting tag.all.
my $get;
$cmock->mock( get => sub {
    return 1 if $_[2] eq 'tag.all';
    return $get->(@_);
});
$get = $cmock->original('get');

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

# With tag.all and an argument, we should just get the argument.
ok $tag->execute('shoot', 'sqlite'), 'Tag sqlite plan with @shoot';
@targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
is @targets, 2, 'Should still have two targets';
ok !$targets[0]->plan->get('@shoot'),
    'Should not have tagged pg plan change "sqlite_change" with @shoot';
is $targets[1]->plan->get('@shoot')->name, 'sqlite_change',
    'Should have tagged sqlite plan change "sqlite_change" with @shoot';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'sqlite_change',
        tag    => '@shoot',
        file   => $targets[1]->plan_file,
    ],
], 'The shoot info message should the sqlite plan getting tagged';

$cmock->unmock_all;

# Without --all or tag.all, we should just get the default target.
isa_ok $tag = App::Sqitch::Command::tag->new({
    sqitch => $sqitch,
    note   => ['here we go again'],
}), $CLASS, 'yet another tag command';
ok $tag->execute('huwah'), 'Tag with @huwah';
@targets = App::Sqitch::Target->all_targets(sqitch => $sqitch);
is @targets, 2, 'Should still have two targets';
is $targets[0]->plan->get('@huwah')->name, 'pg_change',
    'Should have tagged pg plan change "pg_change" with @huwah';
ok !$targets[1]->plan->get('@huwah'),
    'Should not have tagged sqlite plan change "sqlite_change" with @huwah';

is_deeply +MockOutput->get_info, [
    [__x
        'Tagged "{change}" with {tag} in {file}',
        change => 'pg_change',
        tag    => '@huwah',
        file   => $targets[0]->plan_file,
    ],
], 'The huwah info message should the pg plan getting tagged';
