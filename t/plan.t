#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More;
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Exception;
use Test::File;
use Test::Deep;
use Test::File::Contents;
use Encode;
#use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    sqitch
    changes
    position
    load
    _parse
    sort_changes
    open_script
);

my $uri = URI->new('https://github.com/theory/sqitch/');
my $sqitch = App::Sqitch->new(uri => $uri);
isa_ok my $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS;

# Set up some some utility functions for creating changes.
sub blank {
    App::Sqitch::Plan::Blank->new(
        plan    => $plan,
        lspace  => $_[0] // '',
        comment => $_[1] // '',
    );
}

my $prev_tag;
my $prev_change;
my %seen;

sub clear {
    undef $prev_tag;
    undef $prev_change;
    %seen = ();
    return ();
}

my $ts = App::Sqitch::DateTime->new(
    year      => 2012,
    month     => 7,
    day       => 16,
    hour      => 17,
    minute    => 25,
    second    => 7,
    time_zone => 'UTC',
);

sub ts($) {
    my $str = shift || return $ts;
    my @parts = split /[-:T]/ => $str;
    return App::Sqitch::DateTime->new(
        year      => $parts[0],
        month     => $parts[1],
        day       => $parts[2],
        hour      => $parts[3],
        minute    => $parts[4],
        second    => $parts[5],
        time_zone => 'UTC',
    );
}

sub change($) {
    my $p = shift;
    if ( my $op = delete $p->{op} ) {
        @{ $p }{ qw(lopspace operator ropspace) } = split /([+-])/, $op;
        $p->{$_} //= '' for qw(lopspace ropspace);
    }

    $prev_change = App::Sqitch::Plan::Change->new(
        plan          => $plan,
        timestamp     => ts delete $p->{ts},
        planner_name  => 'Barack Obama',
        planner_email => 'potus@whitehouse.gov',
        ( $prev_tag ? ( since_tag => $prev_tag ) : () ),
        %{ $p },
    );
    if (my $duped = $seen{ $p->{name} }) {
        $duped->suffix($prev_tag->format_name);
    }
    $seen{ $p->{name} } = $prev_change;
    $prev_change->id;
    $prev_change->tags;
    return $prev_change;
}

sub tag($) {
    my $p = shift;
    my $ret = delete $p->{ret};
    $prev_tag = App::Sqitch::Plan::Tag->new(
        plan          => $plan,
        change        => $prev_change,
        timestamp     => ts delete $p->{ts},
        planner_name  => 'Barack Obama',
        planner_email => 'potus@whitehouse.gov',
        %{ $p },
    );
    $prev_change->add_tag($prev_tag);
    $prev_tag->id;
    return $ret ? $prev_tag : ();
}

sub prag {
    App::Sqitch::Plan::Pragma->new(
        plan    => $plan,
        lspace  => $_[0] // '',
        hspace  => $_[1] // '',
        name    => $_[2],
        (defined $_[3] ? (lopspace => $_[3]) : ()),
        (defined $_[4] ? (operator => $_[4]) : ()),
        (defined $_[5] ? (ropspace => $_[5]) : ()),
        (defined $_[6] ? (value    => $_[6]) : ()),
        rspace  => $_[7] // '',
        comment => $_[8] // '',
    );
}

my $mocker = Test::MockModule->new($CLASS);
# Do no sorting for now.
my $sorted = 0;
sub sorted () {
    my $ret = $sorted;
    $sorted = 0;
    return $ret;
}
$mocker->mock(sort_changes => sub { $sorted++; shift, shift; @_ });

sub version () {
    prag(
        '', '', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION
    );
}

##############################################################################
# Test parsing.
my $file = file qw(t plans widgets.plan);
my $fh = $file->open('<:encoding(UTF-8)');
ok my $parsed = $plan->_parse($file, $fh),
    'Should parse simple "widgets.plan"';
is sorted, 1, 'Should have sorted changes';
isa_ok $parsed->{changes}, 'App::Sqitch::Plan::ChangeList', 'changes';
isa_ok $parsed->{lines}, 'App::Sqitch::Plan::LineList', 'lines';

cmp_deeply [$parsed->{changes}->items], [
    clear,
    change { name => 'hey', ts => '2012-07-16T14:01:20' },
    change { name => 'you', ts => '2012-07-16T14:01:35' },
    tag {
        name    => 'foo',
        comment => ' look, a tag!',
        ts      => '2012-07-16T14:02:05',
        rspace  => ' '
    },
,
], 'All "widgets.plan" changes should be parsed';

cmp_deeply [$parsed->{lines}->items], [
    clear,
    version,
    blank('', ' This is a comment'),
    blank(),
    blank(' ', ' And there was a blank line.'),
    blank(),
    change { name => 'hey', ts => '2012-07-16T14:01:20' },
    change { name => 'you', ts => '2012-07-16T14:01:35' },

    tag {
        ret     => 1,
        name    => 'foo',
        comment => ' look, a tag!',
        ts      => '2012-07-16T14:02:05',
        rspace  => ' '
    },
], 'All "widgets.plan" lines should be parsed';

# Plan with multiple tags.
$file = file qw(t plans multi.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse multi-tagged "multi.plan"';
is sorted, 2, 'Should have sorted changes twice';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    changes => [
        clear,
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            name          => 'foo',
            comment       => ' look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
        tag { name =>, 'bar' },
        tag { name => 'baz' },
    ],
    lines => [
        clear,
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            ret           => 1,
            name          => 'foo',
            comment       => ' look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        blank('   '),
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
        tag { name =>, 'bar', ret => 1 },
        tag { name => 'baz', ret => 1 },
    ],
}, 'Should have "multi.plan" lines and changes';

# Try a plan with changes appearing without a tag.
$file = file qw(t plans changes-only.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh), 'Should read plan with no tags';
is sorted, 1, 'Should have sorted changes';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    lines => [
        clear,
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        change { name => 'hey' },
        change { name => 'you' },
        change { name => 'whatwhatwhat' },
    ],
    changes => [
        clear,
        change { name => 'hey' },
        change { name => 'you' },
        change { name => 'whatwhatwhat' },
    ],
}, 'Should have lines and changes for tagless plan';

# Try a plan with a bad change name.
$file = file qw(t plans bad-change.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with bad change name';
is $@->ident, 'plan', 'Bad change name error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 4,
    error => __(
        'Invalid name; names must not begin or end in '
         . 'punctuation or end in digits following punctuation',
    ),
), 'And the bad change name error message should be correct';

is sorted, 0, 'Should not have sorted changes';

my @bad_names = (
    '^foo',     # No leading punctuation
    'foo+',     # No trailing punctuation
    'foo+6',    # No trailing punctuation+digit
    'foo+666',  # No trailing punctuation+digits
    '%hi',      # No leading punctuation
    'hi!',      # No trailing punctuation
    'foo@bar',  # No @ allowed at all
);

# Try other invalid change and tag name issues.
for my $name (@bad_names) {
    for my $line ($name, "\@$name") {
        next if $line eq '%hi'; # This would be a pragma.
        my $what = $line =~ /^[@]/ ? 'tag' : 'change';
        my $fh = IO::File->new(\$line, '<:utf8');
        throws_ok { $plan->_parse('baditem', $fh) } 'App::Sqitch::X',
            qq{Should die on plan with bad name "$line"};
        is $@->ident, 'plan', 'Exception ident should be "plan"';
        is $@->message, __x(
            'Syntax error in {file} at line {line}: {error}',
            file => 'baditem',
            line => 1,
            error => __(
                'Invalid name; names must not begin or end in '
                . 'punctuation or end in digits following punctuation',
            )
        ),  qq{And "$line" should trigger the appropriate message};
        is sorted, 0, 'Should not have sorted changes';
    }
}

# Try some valid change and tag names.
my $tsnp = '2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>';
for my $name (
    'foo',     # alpha
    '12',      # digits
    't',       # char
    '6',       # digit
    '阱阪阬',   # multibyte
    'foo/bar', # middle punct
    'beta1',   # ending digit
) {
    # Test a change name.
    my $line = "$name $tsnp";
    my $fh = IO::File->new(\$line, '<:utf8');
    ok my $parsed = $plan->_parse('gooditem', $fh),
        encode_utf8(qq{Should parse "$name"});
    cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
        changes => [ clear, change { name => $name } ],
        lines => [ clear, version, change { name => $name } ],
    }, encode_utf8(qq{Should have line and change for "$name"});

    # Test a tag name.
    my $tag = '@' . $name;
    my $lines = "foo $tsnp\n$tag $tsnp";
    $fh = IO::File->new(\$lines, '<:utf8');
    ok $parsed = $plan->_parse('gooditem', $fh),
        encode_utf8(qq{Should parse "$tag"});
    cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
        changes => [ clear, change { name => 'foo' }, tag { name => $name } ],
        lines => [
            clear,
            version,
            change { name => 'foo' },
            tag { name => $name, ret => 1 }
        ],
    }, encode_utf8(qq{Should have line and change for "$tag"});
}
is sorted, 14, 'Should have sorted changes 12 times';

# Try a plan with reserved tag name @HEAD.
$file = file qw(t plans reserved-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with reserved tag "@HEAD"';
is $@->ident, 'plan', '@HEAD exception should have ident "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 5,
    error => __x(
        '"{name}" is a reserved name',
        name => '@HEAD',
    ),
), 'And the @HEAD error message should be correct';
is sorted, 1, 'Should have sorted changes once';

# Try a plan with reserved tag name @ROOT.
my $root = '@ROOT ' . $tsnp;
$file = file qw(t plans root.plan);
$fh = IO::File->new(\$root, '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with reserved tag "@ROOT"';
is $@->ident, 'plan', '@HEAD exception should have ident "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __x(
        '"{name}" is a reserved name',
        name => '@ROOT',
    ),
), 'And the @HEAD error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with a change name that looks like a sha1 hash.
my $sha1 = '6c2f28d125aff1deea615f8de774599acf39a7a1';
$file = file qw(t plans sha1.plan);
$fh = IO::File->new(\"$sha1 $tsnp", '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with SHA1 change name';
is $@->ident, 'plan', 'The SHA1 error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __x(
        '"{name}" is invalid because it could be confused with a SHA1 ID',
        name => $sha1,
    ),
), 'And the SHA1 error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with a tag but no change.
$file = file qw(t plans tag-no-change.plan);
$fh = IO::File->new(\"\@foo $tsnp\nbar $tsnp", '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with tag but no preceding change';
is $@->ident, 'plan', 'The missing change error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __x(
        'Tag "{tag}" declared without a preceding change',
        tag => 'foo',
    ),
), 'And the missing change error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with dupe tag';
is $@->ident, 'plan', 'The dupe tag error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 10,
    error => __x(
        'Tag "{tag}" duplicates earlier declaration on line {line}',
        tag  => 'bar',
        line => 5,
    ),
), 'And the missing change error message should be correct';
is sorted, 2, 'Should have sorted changes twice';

# Try a plan with a duplicate change within a tag section.
$file = file qw(t plans dupe-change.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with dupe change';
is $@->ident, 'plan', 'The dupe change error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 7,
    error => __x(
        'Change "{change}" duplicates earlier declaration on line {line}',
        change  => 'greets',
        line    => 5,
    ),
), 'And the dupe change error message should be correct';
is sorted, 1, 'Should have sorted changes once';

# Try a plan without a timestamp.
$file = file qw(t plans no-timestamp.plan);
$fh = IO::File->new(\'foo hi <t@heo.ry>', '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no timestamp';
is $@->ident, 'plan', 'The missing timestamp error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __ 'Missing timestamp',
), 'And the missing timestamp error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan without a planner.
$file = file qw(t plans no-planner.plan);
$fh = IO::File->new(\'foo 2012-07-16T23:12:34Z', '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no planner';
is $@->ident, 'plan', 'The missing planner error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __ 'Missing planner name and email',
), 'And the missing planner error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with neither timestamp nor planner.
$file = file qw(t plans no-timestamp-or-planner.plan);
$fh = IO::File->new(\'foo', '<:utf8');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no timestamp or planner';
is $@->ident, 'plan', 'The missing timestamp or planner error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 1,
    error => __ 'Missing timestamp and planner name and email',
), 'And the missing timestamp or planner error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with pragmas.
$file = file qw(t plans pragmas.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with pragmas"';
is sorted, 1, 'Should have sorted changes once';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    changes => [
        clear,
        change { name => 'hey' },
        change { name => 'you' },
    ],
    lines => [
        clear,
        prag( '', ' ', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION),
        prag( '  ', '', 'foo', ' ', '=', ' ', 'bar', '    ', ' lolz'),
        blank(),
        change { name => 'hey' },
        change { name => 'you' },
        blank(),
        prag( '', ' ', 'strict'),
    ],
}, 'Should have "multi.plan" lines and changes';

# Try a plan with deploy/revert operators.
$file = file qw(t plans deploy-and-revert.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with deploy and revert operators';
is sorted, 2, 'Should have sorted changes twice';

cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    changes => [
        clear,
        change { name => 'hey', op => '+' },
        change { name => 'you', op => '+' },
        change { name => 'dr_evil', op => '+  ', lspace => ' ' },
        tag    { name => 'foo' },
        change { name => 'this/rocks', op => '+', pspace => '  ' },
        change { name => 'hey-there', lspace => ' ' },
        change {
            name    => 'dr_evil',
            comment => ' revert!',
            op      => '-',
            rspace  => ' ',
            pspace  => '  '
        },
        tag    { name => 'bar', lspace => ' ' },
    ],
    lines => [
        clear,
        version,
        change { name => 'hey', op => '+' },
        change { name => 'you', op => '+' },
        change { name => 'dr_evil', op => '+  ', lspace => ' ' },
        tag    { name => 'foo', ret => 1 },
        blank( '   '),
        change { name => 'this/rocks', op => '+', pspace => '  ' },
        change { name => 'hey-there', lspace => ' ' },
        change {
            name    => 'dr_evil',
            comment => ' revert!',
            op      => '-',
            rspace  => ' ',
            pspace  => '  '
        },
        tag    { name => 'bar', lspace => ' ', ret => 1 },
    ],
}, 'Should have "deploy-and-revert.plan" lines and changes';

# Try a non-existent plan file with load().
$file = file qw(t hi nonexistent.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with nonexistent plan file';

cmp_deeply [$plan->lines], [version], 'Should have only the version line';
cmp_deeply [$plan->changes], [], 'Should have no changes';
cmp_deeply [$plan->tags], [], 'Should have no tags';

# Try a plan with dependencies.
$file = file qw(t plans dependencies.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan file with dependencies';
ok $parsed = $plan->load, 'Load plan with dependencies file';
is_deeply [$parsed->{changes}->changes], [
    clear,
    change { name => 'roles', op => '+' },
    change { name => 'users', op => '+', pspace => '    ', requires => ['roles'] },
    change { name => 'add_user', op => '+', pspace => ' ', requires => [qw( users roles)] },
    change { name => 'dr_evil', op => '+' },
    tag    { name => 'alpha' },
    change { name => 'users', op => '+', pspace => ' ', requires => ['users@alpha'] },
    change { name => 'dr_evil', op => '-' },
    change {
        name      => 'del_user',
        op        => '+',
        pspace    => ' ',
        requires  => ['users'],
        conflicts => ['dr_evil']
    },
], 'The changes should include the dependencies';
is sorted, 2, 'Should have sorted changes twice';

# Should fail with dependencies on tags.
$file = file qw(t plans tag_dependencies.plan);
$fh = IO::File->new(\"foo $tsnp\n\@bar [:foo] $tsnp", '<:utf8');
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan with tag dependencies';
throws_ok { $plan->_parse($file, $fh) }  'App::Sqitch::X',
    'Should get an exception for tag with dependencies';
is $@->ident, 'plan', 'The tag dependencies error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {line}: {error}',
    file => $file,
    line => 2,
    error => __ 'Tags may not specify dependencies',
), 'And the tag dependencies error message should be correct';

# Make sure that lines() loads the plan.
$file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan file';
cmp_deeply [$plan->lines], [
    clear,
    version,
    blank('', ' This is a comment'),
    blank(),
    blank('', ' And there was a blank line.'),
    blank(),
    change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
    change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
    tag {
        ret           => 1,
        name          => 'foo',
        comment       => ' look, a tag!',
        ts            => '2012-07-16T17:24:07',
        rspace        => ' ',
        planner_name  => 'julie',
        planner_email => 'j@ul.ie',
    },
    blank('   '),
    change { name => 'this/rocks', pspace => '  ' },
    change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
    tag { name =>, 'bar', ret => 1 },
    tag { name => 'baz', ret => 1 },
], 'Lines should be parsed from file';

cmp_deeply [$plan->changes], [
    clear,
    change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
    change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
    tag {
        name          => 'foo',
        comment       => ' look, a tag!',
        ts            => '2012-07-16T17:24:07',
        rspace        => ' ',
        planner_name  => 'julie',
        planner_email => 'j@ul.ie',
    },
    change { name => 'this/rocks', pspace => '  ' },
    change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
    tag { name =>, 'bar' },
    tag { name => 'baz' },
], 'Changes should be parsed from file';
clear, change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' };

my $foo_tag =  tag {
    ret           => 1,
    name          => 'foo',
    comment       => ' look, a tag!',
    ts            => '2012-07-16T17:24:07',
    rspace        => ' ',
    planner_name  => 'julie',
    planner_email => 'j@ul.ie',
};

change { name => 'hey-there', rspace => ' ', comment => ' trailing comment!' };
cmp_deeply [$plan->tags], [
    $foo_tag,
    tag { name =>, 'bar', ret => 1 },
    tag { name => 'baz', ret => 1 },
], 'Should get all tags from tags()';
is sorted, 2, 'Should have sorted changes twice';

ok $parsed = $plan->load, 'Load should parse plan from file';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    lines => [
        clear,
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            ret           => 1,
            name          => 'foo',
            comment       => ' look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        blank('   '),
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
        tag { name =>, 'bar', ret => 1 },
        tag { name => 'baz', ret => 1 },
    ],
    changes => [
        clear,
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            name          => 'foo',
            comment       => ' look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', comment => ' trailing comment!', rspace => ' ' },
        tag { name =>, 'bar' },
        tag { name => 'baz' },
    ],
}, 'And the parsed file should have lines and changes';
is sorted, 2, 'Should have sorted changes twice';

##############################################################################
# Test the interator interface.
can_ok $plan, qw(
    index_of
    get
    seek
    reset
    next
    current
    peek
    do
);

is $plan->position, -1, 'Position should start at -1';
is $plan->current, undef, 'Current should be undef';
ok my $change = $plan->next, 'Get next change';
isa_ok $change, 'App::Sqitch::Plan::Change', 'First change';
is $change->name, 'hey', 'It should be the first change';
is $plan->position, 0, 'Position should be at 0';
is $plan->count, 4, 'Count should be 4';
is $plan->current, $change, 'Current should be current';
is $plan->change_at(0), $change, 'Should get first change from change_at(0)';

ok my $next = $plan->peek, 'Peek to next change';
isa_ok $next, 'App::Sqitch::Plan::Change', 'Peeked change';
is $next->name, 'you', 'Peeked change should be second change';
is $plan->last->format_name, 'hey-there', 'last() should return last change';
is $plan->current, $change, 'Current should still be current';
is $plan->peek, $next, 'Peek should still be next';
is $plan->next, $next, 'Next should be the second change';
is $plan->position, 1, 'Position should be at 1';
is $plan->change_at(1), $next, 'Should get second change from change_at(1)';

ok my $third = $plan->peek, 'Peek should return an object';
isa_ok $third, 'App::Sqitch::Plan::Change', 'Third change';
is $third->name, 'this/rocks', 'It should be the foo tag';
is $plan->current, $next, 'Current should be the second change';
is $plan->next, $third, 'Should get third change next';
is $plan->position, 2, 'Position should be at 2';
is $plan->current, $third, 'Current should be third change';
is $plan->change_at(2), $third, 'Should get third change from change_at(1)';

ok my $fourth = $plan->next, 'Get fourth change';
isa_ok $fourth, 'App::Sqitch::Plan::Change', 'Fourth change';
is $fourth->name, 'hey-there', 'Fourth change should be "hey-there"';
is $plan->position, 3, 'Position should be at 3';

is $plan->peek, undef, 'Peek should return undef';
is $plan->next, undef, 'Next should return undef';
is $plan->position, 4, 'Position should be at 7';

is $plan->next, undef, 'Next should still return undef';
is $plan->position, 4, 'Position should still be at 7';
ok $plan->reset, 'Reset the plan';

is $plan->position, -1, 'Position should be back at -1';
is $plan->current, undef, 'Current should still be undef';
is $plan->next, $change, 'Next should return the first change again';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $change, 'Current should be first change';
is $plan->index_of($change->name), 0, "Index of change should be 0";
is $plan->get($change->name), $change, 'Should be able to get change 0 by name';
is $plan->find($change->name), $change, 'Should be able to find change 0 by name';
is $plan->get($change->id), $change, 'Should be able to get change 0 by ID';
is $plan->find($change->id), $change, 'Should be able to find change 0 by ID';
is $plan->index_of('@bar'), 3, 'Index of @bar should be 3';
is $plan->get('@bar'), $fourth, 'Should be able to get hey-there via @bar';
is $plan->get($fourth->id), $fourth, 'Should be able to get hey-there via @bar ID';
is $plan->find('@bar'), $fourth, 'Should be able to find hey-there via @bar';
is $plan->find($fourth->id), $fourth, 'Should be able to find hey-there via @bar ID';
ok $plan->seek('@bar'), 'Seek to the "@bar" change';
is $plan->position, 3, 'Position should be at 3 again';
is $plan->current, $fourth, 'Current should be fourth again';
is $plan->index_of('you'), 1, 'Index of you should be 1';
is $plan->get('you'), $next, 'Should be able to get change 1 by name';
is $plan->find('you'), $next, 'Should be able to find change 1 by name';
ok $plan->seek('you'), 'Seek to the "you" change';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';
is $plan->index_of('baz'), undef, 'Index of baz should be undef';
is $plan->index_of('@baz'), 3, 'Index of @baz should be 3';
ok $plan->seek('@baz'), 'Seek to the "baz" change';
is $plan->position, 3, 'Position should be at 3 again';
 is $plan->current, $fourth, 'Current should be fourth again';

is $plan->change_at(0), $change,  'Should still get first change from change_at(0)';
is $plan->change_at(1), $next,  'Should still get second change from change_at(1)';
is $plan->change_at(2), $third, 'Should still get third change from change_at(1)';

# Make sure seek() chokes on a bad change name.
throws_ok { $plan->seek('nonesuch') } 'App::Sqitch::X',
    'Should die seeking invalid change';
is $@->ident, 'plan', 'Invalid seek change error ident should be "plan"';
is $@->message, __x(
    'Cannot find change "{change}" in plan',
    change => 'nonesuch',
), 'And the failure message should be correct';

# Get all!
my @changes = ($change, $next, $third, $fourth);
cmp_deeply [$plan->changes], \@changes, 'All should return all changes';
ok $plan->reset, 'Reset the plan again';
$plan->do(sub {
    is shift, $changes[0], 'Change ' . $changes[0]->name . ' should be passed to do sub';
    is $_, $changes[0], 'Change ' . $changes[0]->name . ' should be the topic in do sub';
    shift @changes;
});

# There should be no more to iterate over.
$plan->do(sub { fail 'Should not get anything passed to do()' });

##############################################################################
# Test writing the plan.
can_ok $plan, 'write_to';
my $to = file 'plan.out';
END { unlink $to }
file_not_exists_ok $to;
ok $plan->write_to($to), 'Write out the file';
file_exists_ok $to;
my $v = App::Sqitch->VERSION;
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)'),
    'The contents should look right';

##############################################################################
# Test _is_valid.
can_ok $plan, '_is_valid';

for my $name (@bad_names) {
    throws_ok { $plan->_is_valid( tag => $name) } 'App::Sqitch::X',
        qq{Should find "$name" invalid};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: tags must not begin with punctuation }
        . 'or end in punctuation or digits following punctuation',
        name => $name,
    ), qq{And the "$name" error message should be correct};
}

# Try some valid names.
for my $name (
    'foo',     # alpha
    '12',      # digits
    't',       # char
    '6',       # digit
    '阱阪阬',   # multibyte
    'foo/bar', # middle punct
    'beta1',   # ending digit
) {
    my $disp = Encode::encode_utf8($name);
    ok $plan->_is_valid(change => $name), qq{Name "$disp" sould be valid};
}

##############################################################################
# Try adding a tag.
ok my $tag = $plan->add_tag('w00t'), 'Add tag "w00t"';
is $plan->count, 4, 'Should have 4 changes';
is $plan->index_of('@w00t'), 3, 'Should find "@w00t at index 3';
is $plan->last->name, 'hey-there', 'Last change should be "hey-there"';
is_deeply [map { $_->name } $plan->last->tags], [qw(bar baz w00t)],
    'The w00t tag should be on the last change';
isa_ok $tag, 'App::Sqitch::Plan::Tag';
is $tag->name, 'w00t', 'The returned tag should be @w00t';
is $tag->change, $plan->last, 'The @w00t change should be the last change';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)')
    . $tag->as_string . $/,
    'The contents should include the "w00t" tag';

# Try passing the tag name with a leading @.
ok my $tag2 = $plan->add_tag('@alpha'), 'Add tag "@alpha"';
is $plan->index_of('@alpha'), 3, 'Should find "@alpha at index 3';
is $tag2->name, 'alpha', 'The returned tag should be @alpha';
is $tag2->change, $plan->last, 'The @alpha change should be the last change';

# Should choke on a duplicate tag.
throws_ok { $plan->add_tag('w00t') } 'App::Sqitch::X',
    'Should get error trying to add duplicate tag';
is $@->ident, 'plan', 'Duplicate tag error ident should be "plan"';
is $@->message, __x(
    'Tag "{tag}" already exists',
    tag => '@w00t',
), 'And the error message should report it as a dupe';

# Should choke on an invalid tag names.
for my $name (@bad_names, 'foo#bar') {
    throws_ok { $plan->add_tag($name) } 'App::Sqitch::X',
        qq{Should get error for invalid tag "$name"};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: tags must not begin with punctuation }
        . 'or end in punctuation or digits following punctuation',
        name => $name,
    ), qq{And the "$name" error message should be correct};
}

throws_ok { $plan->add_tag('HEAD') } 'App::Sqitch::X',
    'Should get error for reserved tag "HEAD"';
is $@->ident, 'plan', 'Reserved tag "HEAD" error ident should be "plan"';
is $@->message, __x(
    '"{name}" is a reserved name',
    name => 'HEAD',
), 'And the reserved tag "HEAD" message should be correct';

throws_ok { $plan->add_tag('ROOT') } 'App::Sqitch::X',
    'Should get error for reserved tag "ROOT"';
is $@->ident, 'plan', 'Reserved tag "ROOT" error ident should be "plan"';
is $@->message, __x(
    '"{name}" is a reserved name',
    name => 'ROOT',
), 'And the reserved tag "ROOT" message should be correct';

throws_ok { $plan->add_tag($sha1) } 'App::Sqitch::X',
    'Should get error for a SHA1 tag';
is $@->ident, 'plan', 'SHA1 tag error ident should be "plan"';
is $@->message, __x(
    '"{name}" is invalid because it could be confused with a SHA1 ID',
    name => $sha1,,
), 'And the reserved name error should be output';

##############################################################################
# Try adding a change.
ok my $new_change = $plan->add('booyah'), 'Add change "booyah"';
is $plan->count, 5, 'Should have 5 changes';
is $plan->index_of('booyah'), 4, 'Should find "booyah at index 4';
is $plan->last->name, 'booyah', 'Last change should be "booyah"';
isa_ok $new_change, 'App::Sqitch::Plan::Change';
is $new_change->as_string, join (' ',
    'booyah',
    $new_change->timestamp->as_string,
    $new_change->format_planner,
), 'Should have plain stringification of "booya"';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)')
    . $tag->as_string . "\n"
    . $tag2->as_string . "\n\n"
    . $new_change->as_string . $/,
    'The contents should include the "booyah" change';

# Make sure dependencies are verified.
ok $new_change = $plan->add('blow', ['booyah']), 'Add change "blow"';
is $plan->count, 6, 'Should have 6 changes';
is $plan->index_of('blow'), 5, 'Should find "blow at index 5';
is $plan->last->name, 'blow', 'Last change should be "blow"';
is $new_change->as_string,
    'blow [:booyah] ' . $new_change->timestamp->as_string . ' '
    . $new_change->format_planner,
    'Should have nice stringification of "blow :booyah"';
is [$plan->lines]->[-1], $new_change,
    'The new change should have been appended to the lines, too';

# Should choke on a duplicate change.
throws_ok { $plan->add('blow') } 'App::Sqitch::X',
    'Should get error trying to add duplicate change';
is $@->ident, 'plan', 'Duplicate change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" already exists.\nUse "sqitch rework" to copy and rework it},
    change => 'blow',
), 'And the error message should suggest "rework"';

# Should choke on an invalid change names.
for my $name (@bad_names) {
    throws_ok { $plan->add($name) } 'App::Sqitch::X',
        qq{Should get error for invalid change "$name"};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: changes must not begin with punctuation }
        . 'or end in punctuation or digits following punctuation',
        name => $name,
    ), qq{And the "$name" error message should be correct};
}

# Try a reserved name.
throws_ok { $plan->add('HEAD') } 'App::Sqitch::X',
    'Should get error for reserved name "HEAD"';
is $@->ident, 'plan', 'Reserved name "HEAD" error ident should be "plan"';
is $@->message, __x(
    '"{name}" is a reserved name',
    name => 'HEAD',
), 'And the reserved name "HEAD" message should be correct';
throws_ok { $plan->add('ROOT') } 'App::Sqitch::X',
    'Should get error for reserved name "ROOT"';
is $@->ident, 'plan', 'Reserved name "ROOT" error ident should be "plan"';
is $@->message, __x(
    '"{name}" is a reserved name',
    name => 'ROOT',
), 'And the reserved name "ROOT" message should be correct';

# Try an invalid dependency.
throws_ok { $plan->add('whu', ['nonesuch' ] ) } 'App::Sqitch::X',
    'Should get failure for failed dependency';
is $@->ident, 'plan', 'Dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot add change "{change}": requires unknown change "{req}"',
    change => 'whu',
    req    => 'nonesuch',
), 'The dependency error should be correct';

# Should choke on an unknown tag, too.
throws_ok { $plan->add('whu', ['@nonesuch' ] ) } 'App::Sqitch::X',
    'Should get failure for failed tag dependency';
is $@->ident, 'plan', 'Tag dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot add change "{change}": requires unknown change "{req}"',
    change => 'whu',
    req    => '@nonesuch',
), 'The tag dependency error should be correct';

# Should choke on a change that looks like a SHA1.
throws_ok { $plan->add($sha1) } 'App::Sqitch::X',
    'Should get error for a SHA1 change';
is $@->ident, 'plan', 'SHA1 tag error ident should be "plan"';
is $@->message, __x(
    '"{name}" is invalid because it could be confused with a SHA1 ID',
    name => $sha1,,
), 'And the reserved name error should be output';

##############################################################################
# Try reworking a change.
can_ok $plan, 'rework';
ok my $rev_change = $plan->rework('you'), 'Rework change "you"';
isa_ok $rev_change, 'App::Sqitch::Plan::Change';
is $rev_change->name, 'you', 'Reworked change should be "you"';
ok my $orig = $plan->change_at($plan->first_index_of('you')),
    'Get original "you" change';
is $orig->name, 'you', 'It should also be named "you"';
is $orig->suffix, '@bar', 'And its suffix should be "@bar"';
is $orig->deploy_file, $sqitch->deploy_dir->file('you@bar.sql'),
    'The original file should now be named you@bar.sql';
is $rev_change->suffix, '', 'But the reworked change should have no suffix';
is $rev_change->as_string,
    'you [:you@bar] ' . $rev_change->timestamp->as_string . ' '
    . $rev_change->format_planner,
    'It should require the previous "you" change';
is [$plan->lines]->[-1], $rev_change,
    'The new "you" should have been appended to the lines, too';

# Make sure it was appended to the plan.
is $plan->index_of('you@HEAD'), 6, 'It should be at position 6';
is $plan->count, 7, 'The plan count should be 7';

# Tag and add again, to be sure we can do it multiple times.
ok $plan->add_tag('@beta1'), 'Tag @beta1';
ok my $rev_change2 = $plan->rework('you'), 'Rework change "you" again';
isa_ok $rev_change2, 'App::Sqitch::Plan::Change';
is $rev_change2->name, 'you', 'New reworked change should be "you"';
ok $orig = $plan->change_at($plan->first_index_of('you')),
    'Get original "you" change again';
is $orig->name, 'you', 'It should still be named "you"';
is $orig->suffix, '@bar', 'And it should still have the suffix "@bar"';
ok $rev_change = $plan->get('you@beta1'), 'Get you@beta1';
is $rev_change->name, 'you', 'The second "you" should be named that';
is $rev_change->suffix, '@beta1', 'And the second change should now have the suffx "@beta1"';
is $rev_change2->suffix, '', 'But the new reworked change should have no suffix';
is $rev_change2->as_string,
    'you [:you@beta1] ' . $rev_change2->timestamp->as_string . ' '
    . $rev_change2->format_planner,
    'It should require the previous "you" change';
is [$plan->lines]->[-1], $rev_change2,
    'The new reworking should have been appended to the lines';

# Make sure it was appended to the plan.
is $plan->index_of('you@HEAD'), 7, 'It should be at position 7';
is $plan->count, 8, 'The plan count should be 8';

# Try a nonexistent change name.
throws_ok { $plan->rework('nonexistent') } 'App::Sqitch::X',
    'rework should die on nonexistent change';
is $@->ident, 'plan', 'Nonexistent change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" does not exist.\nUse "sqitch add {change}" to add it to the plan},
    change => 'nonexistent',
), 'And the error should suggest "sqitch add"';

# Try reworking without an intervening tag.
throws_ok { $plan->rework('you') } 'App::Sqitch::X',
    'rework_stpe should die on lack of intervening tag';
is $@->ident, 'plan', 'Missing tag error ident should be "plan"';
is $@->message, __x(
    qq{Cannot rework "{change}" without an intervening tag.\nUse "sqitch tag" to create a tag and try again},
    change => 'you',
), 'And the error should suggest "sqitch tag"';

# Make sure it checks dependencies.
throws_ok { $plan->rework('booyah', ['nonesuch' ] ) } 'App::Sqitch::X',
    'rework should die on failed dependency';
is $@->ident, 'plan', 'Rework dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot rework change "{change}": requires unknown change "{req}"',
    change => 'booyah',
    req    => 'nonesuch',
), 'The rework dependency error should be correct';

##############################################################################
# Try a plan with a duplicate change in different tag sections.
$file = file qw(t plans dupe-change-diff-tag.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan shoud work plan with dupe change across tags';
cmp_deeply [ $plan->lines ], [
    clear,
    version,
    change { name => 'whatever' },
    tag    { name => 'foo', ret => 1 },
    blank(),
    change { name => 'hi' },
    tag    { name => 'bar', ret => 1 },
    blank(),
    change { name => 'greets' },
    change { name => 'whatever' },
], 'Lines with dupe change should be read from file';

cmp_deeply [ $plan->changes ], [
    clear,
    change { name => 'whatever' },
    tag    { name => 'foo' },
    change { name => 'hi' },
    tag    { name => 'bar' },
    change { name => 'greets' },
    change { name => 'whatever' },
], 'Noes with dupe change should be read from file';
is sorted, 3, 'Should have sorted changes three times';

# Try to find whatever.
throws_ok { $plan->index_of('whatever') } 'App::Sqitch::X',
    'Should get an error trying to find dupe key.';
is $@->ident, 'plan', 'Dupe key error ident should be "plan"';
is $@->message, __x(
    'Key {key} at multiple indexes',
    key => 'whatever',
), 'Dupe key error message should be correct';
is $plan->index_of('whatever@HEAD'), 3, 'Should get 3 for whatever@HEAD';
is $plan->index_of('whatever@bar'), 0, 'Should get 0 for whatever@bar';

# Make sure seek works, too.
throws_ok { $plan->seek('whatever') } 'App::Sqitch::X',
    'Should get an error seeking dupe key.';
is $@->ident, 'plan', 'Dupe key error ident should be "plan"';
is $@->message, __x(
    'Key {key} at multiple indexes',
    key => 'whatever',
), 'Dupe key error message should be correct';

is $plan->index_of('whatever@HEAD'), 3, 'Should find whatever@HEAD at index 3';
is $plan->index_of('whatever@bar'), 0, 'Should find whatever@HEAD at index 0';
is $plan->first_index_of('whatever'), 0,
    'Should find first instance of whatever at index 0';
is $plan->first_index_of('whatever', '@bar'), 3,
    'Should find first instance of whatever after @bar at index 5';
ok $plan->seek('whatever@HEAD'), 'Seek whatever@HEAD';
is $plan->position, 3, 'Position should be 3';
ok $plan->seek('whatever@bar'), 'Seek whatever@bar';
is $plan->position, 0, 'Position should be 0';
is $plan->last_tagged_change->name, 'hi', 'Last tagged change should be "hi"';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy stuff))->stringify;
END { remove_tree 'sql' };

can_ok $CLASS, 'open_script';
my $change_file = file qw(sql deploy bar.sql);
$fh = $change_file->open('>') or die "Cannot open $change_file: $!\n";
$fh->say('-- This is a comment');
$fh->close;
ok $fh = $plan->open_script($change_file), 'Open bar.sql';
is $fh->getline, "-- This is a comment\n", 'It should be the right file';
$fh->close;

file(qw(sql deploy baz.sql))->touch;
ok $fh = $plan->open_script(file qw(sql deploy baz.sql)), 'Open baz.sql';
is $fh->getline, undef, 'It should be empty';

##############################################################################
# Test sort_changes()
$mocker->unmock('sort_changes');
can_ok $CLASS, 'sort_changes';
my @deps;
my $mock_change = Test::MockModule->new('App::Sqitch::Plan::Change');
$mock_change->mock(requires => sub { @{ shift(@deps)->{requires} } });

sub changes {
    clear;
    map {
        change { name => $_ };
    } @_;
}

# Start with no dependencies.
my %ddep = ( requires => [], conflicts => [] );
@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes({}, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when no dependencies';

@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when no prepreqs';

# Have that require this.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when that requires this';

# Have other require that.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when other requires that';

# Have this require other.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(other this that)], 'Should get other first when this requires it';

# Have other other require taht.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(that other this)], 'Should get that, other, this now';

# Have this require other and that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(other that this)], 'Should get other, that, this now';

# Have this require other and that, and other requore that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_changes(changes qw(this that other))],
    [changes qw(that other this)], 'Should get that, other, this again';

# Have that require a tag.
@deps = ({%ddep}, {%ddep, requires => ['@howdy']}, {%ddep});
cmp_deeply [$plan->sort_changes({'@howdy' => 2 }, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when requiring a tag';

# Requires a step as of a tag.
@deps = ({%ddep}, {%ddep, requires => ['foo@howdy']}, {%ddep});
cmp_deeply [$plan->sort_changes({'foo' => 1, '@howdy' => 2 }, changes qw(this that other))],
    [changes qw(this that other)],
    'Should get original order when requiring a step as-of a tag';

# Should die if the step comes *after* the specified tag.
@deps = ({%ddep}, {%ddep, requires => ['foo@howdy']}, {%ddep});
throws_ok { $plan->sort_changes({'foo' => 3, '@howdy' => 2 }, changes qw(this that other)) }
    'App::Sqitch::X', 'Should get failure for a step after a tag';
is $@->ident, 'plan', 'Step after tag error ident should be "plan"';
is $@->message, __x(
    'Unknown change "{required}" required by change "{change}"',
    required => 'foo@howdy',
    change   => 'that',
),  'And we the unknown change as-of a tag message should be correct';

# Add a cycle.
@deps = ({%ddep, requires => ['that']}, {%ddep, requires => ['this']}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } 'App::Sqitch::X',
    'Should get failure for a cycle';
is $@->ident, 'plan', 'Cycle error ident should be "plan"';
is $@->message, __x(
    'Dependency cycle detected beween changes {changes}',
    changes => __x('"{quoted}"', quoted => 'this')
             . __ ' and ' . __x('"{quoted}"', quoted => 'that')
), 'The cycle error message should be correct';

# Add an extended cycle.
@deps = (
    {%ddep, requires => ['that']},
    {%ddep, requires => ['other']},
    {%ddep, requires => ['this']}
);
throws_ok { $plan->sort_changes(changes qw(this that other)) } 'App::Sqitch::X',
    'Should get failure for a two-hop cycle';
is $@->ident, 'plan', 'Two-hope cycle error ident should be "plan"';
is $@->message, __x(
    'Dependency cycle detected beween changes {changes}',
    changes => join( __ ', ', map {
        __x('"{quoted}"', quoted => $_)
    } qw(this that)) . __ ' and ' . __x('"{quoted}"', quoted => 'other')
), 'The two-hop cycle error message should be correct';

# Okay, now deal with depedencies from ealier change sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes({ foo => 1}, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep, requires => ['sqitch']}, {%ddep});
cmp_deeply [$plan->sort_changes({sqitch => 1 }, changes qw(this that other))],
    [changes qw(other that this)], 'Should get other, that, this with earlier dependncy';

# Make sure it fails on unknown previous dependencies.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } 'App::Sqitch::X',
    'Should die on unknown dependency';
is $@->ident, 'plan', 'Unknown dependency error ident should be "plan"';
is $@->message, __x(
    'Unknown change "{required}" required by change "{change}"',
    required => 'foo',
    change   => 'this',
), 'And the error should point to the offending change';

# Okay, now deal with depedencies from ealier change sections.
@deps = ({%ddep, requires => ['@foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } 'App::Sqitch::X',
    'Should die on unknown tag dependency';
is $@->ident, 'plan', 'Unknown tag dependency error ident should be "plan"';
is $@->message, __x(
    'Unknown change "{required}" required by change "{change}"',
    required => '@foo',
    change   => 'this',
), 'And the error should point to the offending change';

##############################################################################
# Test dependency testing.
can_ok $plan, '_check_dependencies';
$mock_change->unmock('requires');

for my $req (qw(hi greets whatever @foo whatever@foo)) {
    $change = App::Sqitch::Plan::Change->new(
        plan     => $plan,
        name     => 'lazy',
        requires => [$req],
    );
    ok $plan->_check_dependencies($change, 'add'),
        qq{Dependency on "$req" should succeed};
}

for my $req (qw(wanker @blah greets@foo)) {
    $change = App::Sqitch::Plan::Change->new(
        plan     => $plan,
        name     => 'lazy',
        requires => [$req],
    );
    throws_ok { $plan->_check_dependencies($change, 'bark') } 'App::Sqitch::X',
        qq{Should get error trying to depend on "$req"};
    is $@->ident, 'plan', qq{Dependency "req" error ident should be "plan"};
    is $@->message, __x(
        'Cannot rework change "{change}": requires unknown change "{req}"',
        change => 'lazy',
        req    => $req,
    ), qq{And should get unknown dependency message for "$req"};
}

done_testing;
