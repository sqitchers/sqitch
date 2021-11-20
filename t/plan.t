#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Exception;
use Test::File;
use Test::Deep;
use Test::File::Contents;
use Encode;
#use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use App::Sqitch::DateTime;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    sqitch
    target
    file
    changes
    position
    load
    syntax_version
    project
    uri
    _parse
    check_changes
    open_script
);

my $config = TestConfig->new('core.engine' => 'sqlite');
my $sqitch = App::Sqitch->new( config => $config );
my $target = App::Sqitch::Target->new( sqitch => $sqitch );
isa_ok my $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target),
    $CLASS;
is $plan->file, $target->plan_file, 'File should be coopied from Target';

# Set up some some utility functions for creating changes.
sub blank {
    App::Sqitch::Plan::Blank->new(
        plan   => $plan,
        lspace => $_[0] // '',
        note   => $_[1] // '',
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

my $vivify = 0;
my $project;

sub dep($) {
    App::Sqitch::Plan::Depend->new(
        plan    => $plan,
        (defined $project ? (project => $project) : ()),
        %{ App::Sqitch::Plan::Depend->parse(shift) },
    )
}

sub change($) {
    my $p = shift;
    if ( my $op = delete $p->{op} ) {
        @{ $p }{ qw(lopspace operator ropspace) } = split /([+-])/, $op;
        $p->{$_} //= '' for qw(lopspace ropspace);
    }

    $p->{requires} = [ map { dep $_ } @{ $p->{requires} } ]
        if $p->{requires};
    $p->{conflicts} = [ map { dep "!$_" } @{ $p->{conflicts} }]
        if $p->{conflicts};

    $prev_change = App::Sqitch::Plan::Change->new(
        plan          => $plan,
        timestamp     => ts delete $p->{ts},
        planner_name  => 'Barack Obama',
        planner_email => 'potus@whitehouse.gov',
        ( $prev_tag    ? ( since_tag => $prev_tag    ) : () ),
        ( $prev_change ? ( parent    => $prev_change ) : () ),
        %{ $p },
    );
    if (my $duped = $seen{ $p->{name} }) {
        $duped->add_rework_tags(map { $seen{$_}-> tags } @{ $p->{rtag} });
    }
    $seen{ $p->{name} } = $prev_change;
    if ($vivify) {
        $prev_change->id;
        $prev_change->tags;
    }
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
    $prev_tag->id, if $vivify;
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
        note    => $_[8] // '',
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
$mocker->mock(check_changes => sub { $sorted++; shift, shift, shift; @_ });

sub version () {
    prag(
        '', '', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION
    );
}

##############################################################################
# Test parsing.
my $file = file qw(t plans widgets.plan);
my $fh = $file->open('<:utf8_strict');
ok my $parsed = $plan->_parse($file, $fh),
    'Should parse simple "widgets.plan"';
is sorted, 1, 'Should have sorted changes';
isa_ok $parsed->{changes}, 'ARRAY', 'changes';
isa_ok $parsed->{lines}, 'ARRAY', 'lines';

cmp_deeply $parsed->{changes}, [
    clear,
    change { name => 'hey', ts => '2012-07-16T14:01:20' },
    change { name => 'you', ts => '2012-07-16T14:01:35' },
    tag {
        name   => 'foo',
        note   => 'look, a tag!',
        ts     => '2012-07-16T14:02:05',
        rspace => ' '
    },
,
], 'All "widgets.plan" changes should be parsed';

cmp_deeply $parsed->{lines}, [
    clear,
    version,
    prag( '', '', 'project', '', '=', '', 'widgets'),
    blank('', 'This is a note'),
    blank(),
    blank(' ', 'And there was a blank line.'),
    blank(),
    change { name => 'hey', ts => '2012-07-16T14:01:20' },
    change { name => 'you', ts => '2012-07-16T14:01:35' },

    tag {
        ret    => 1,
        name   => 'foo',
        note   => 'look, a tag!',
        ts     => '2012-07-16T14:02:05',
        rspace => ' '
    },
], 'All "widgets.plan" lines should be parsed';

# Plan with multiple tags.
$file = file qw(t plans multi.plan);
$fh = $file->open('<:utf8_strict');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse multi-tagged "multi.plan"';
is sorted, 2, 'Should have sorted changes twice';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    project        => 'multi',
}, 'Should have captured the multi pragmas';
cmp_deeply $parsed, {
    changes => [
        clear,
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            name          => 'foo',
            note          => 'look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
        tag { name =>, 'bar' },
        tag { name => 'baz' },
    ],
    lines => [
        clear,
        version,
        prag( '', '', 'project', '', '=', '', 'multi'),
        blank('', 'This is a note'),
        blank(),
        blank('', 'And there was a blank line.'),
        blank(),
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            ret           => 1,
            name          => 'foo',
            note          => 'look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        blank('   '),
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
        tag { name =>, 'bar', ret => 1 },
        tag { name => 'baz', ret => 1 },
    ],
}, 'Should have "multi.plan" lines and changes';

# Try a plan with changes appearing without a tag.
$file = file qw(t plans changes-only.plan);
$fh = $file->open('<:utf8_strict');
ok $parsed = $plan->_parse($file, $fh), 'Should read plan with no tags';
is sorted, 1, 'Should have sorted changes';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    project        => 'changes_only',
}, 'Should have captured the changes-only pragmas';
cmp_deeply $parsed, {
    lines => [
        clear,
        version,
        prag( '', '', 'project', '', '=', '', 'changes_only'),
        blank('', 'This is a note'),
        blank(),
        blank('', 'And there was a blank line.'),
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

# Try plans with DOS line endings.
$file = file qw(t plans dos.plan);
$fh = $file->open('<:utf8_strict');
ok $parsed = $plan->_parse($file, $fh), 'Should read plan with DOS line endings';
is sorted, 1, 'Should have sorted changes';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    project        => 'dos',
}, 'Should have captured the dos pragmas';

# Try a plan with a bad change name.
$file = file qw(t plans bad-change.plan);
$fh = $file->open('<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with bad change name';
is $@->ident, 'parse', 'Bad change name error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 5,
    error => __(
        qq{Invalid name; names must not begin with punctuation, }
        . 'contain "@", ":", "#", or blanks, or end in punctuation or digits following punctuation',
    ),
), 'And the bad change name error message should be correct';

is sorted, 0, 'Should not have sorted changes';

my @bad_names = (
    '^foo',     # No leading punctuation
    'foo^',     # No trailing punctuation
    'foo^6',    # No trailing punctuation+digit
    'foo^666',  # No trailing punctuation+digits
    '%hi',      # No leading punctuation
    'hi!',      # No trailing punctuation
    'foo@bar',  # No @ allowed at all
    'foo:bar',  # No : allowed at all
    '+foo',     # No leading +
    '-foo',     # No leading -
    '@foo',     # No leading @
);

# Try other invalid change and tag name issues.
my $prags = '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION
    . "\n%project=test\n\n";
for my $name (@bad_names) {
    for my $line ("+$name", "\@$name") {
        next if $line eq '%hi'; # This would be a pragma.
        my $buf = $prags . $line;
        my $what = $line =~ /^[@]/ ? 'tag' : 'change';
        my $fh = IO::File->new(\$buf, '<:utf8_strict');
        throws_ok { $plan->_parse('baditem', $fh) } 'App::Sqitch::X',
            qq{Should die on plan with bad name "$line"};
        is $@->ident, 'parse', 'Exception ident should be "parse"';
        is $@->message, __x(
            'Syntax error in {file} at line {lineno}: {error}',
            file => 'baditem',
            lineno => 4,
            error => __(
                qq{Invalid name; names must not begin with punctuation, }
                . 'contain "@", ":", "#", or blanks, or end in punctuation or digits following punctuation',
            )
        ),  qq{And "$line" should trigger the appropriate message};
        is sorted, 0, 'Should not have sorted changes';
    }
}

# Try some valid change and tag names.
my $tsnp = '2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>';
my $foo_proj = App::Sqitch::Plan::Pragma->new(
    plan     => $plan,
    name     => 'project',
    value    => 'foo',
    operator => '=',
);
for my $name (
    'foo',     # alpha
    '12',      # digits
    't',       # char
    '6',       # digit
    '阱阪阬',   # multibyte
    'foo/bar', # middle punct
    'beta1',   # ending digit
    'foo_',    # ending underscore
    '_foo',    # leading underscore
    'v1.0-1b', # punctuation followed by digit in middle
    'v1.2-1',  # version number with dash
    'v1.2+1',  # version number with plus
    'v1.2_1',  # version number with underscore
) {
    # Test a change name.
    my $lines = encode_utf8 "\%project=foo\n\n$name $tsnp";
    my $fh = IO::File->new(\$lines, '<:utf8_strict');
    ok my $parsed = $plan->_parse('ooditem', $fh),
        encode_utf8(qq{Should parse "$name"});
    cmp_deeply delete $parsed->{pragmas}, {
        syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
        project        => 'foo',
    }, encode_utf8("Should have captured the $name pragmas");
    cmp_deeply $parsed, {
        changes => [ clear, change { name => $name } ],
        lines => [ clear, version, $foo_proj, blank, change { name => $name } ],
    }, encode_utf8(qq{Should have pragmas in plan with change "$name"});

    # Test a tag name.
    my $tag = '@' . $name;
    $lines = encode_utf8 "\%project=foo\n\nfoo $tsnp\n$tag $tsnp";
    $fh = IO::File->new(\$lines, '<:utf8_strict');
    ok $parsed = $plan->_parse('gooditem', $fh),
        encode_utf8(qq{Should parse "$tag"});
    cmp_deeply delete $parsed->{pragmas}, {
        syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
        project        => 'foo',
    }, encode_utf8(qq{Should have pragmas in plan with tag "$name"});
    cmp_deeply $parsed, {
        changes => [ clear, change { name => 'foo' }, tag { name => $name } ],
        lines => [
            clear,
            version,
            $foo_proj,
            blank,
            change { name => 'foo' },
            tag { name => $name, ret => 1 }
        ],
    }, encode_utf8(qq{Should have line and change for "$tag"});
}
is sorted, 26, 'Should have sorted changes 18 times';

# Try planning with other reserved names.
for my $reserved (qw(HEAD ROOT)) {
    my $root = $prags . '@' . $reserved . " $tsnp";
    $file = file qw(t plans), "$reserved.plan";
    $fh = IO::File->new(\$root, '<:utf8_strict');
    throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
        qq{Should die on plan with reserved tag "\@$reserved"};
    is $@->ident, 'parse', qq{\@$reserved exception should have ident "plan"};
    is $@->message, __x(
        'Syntax error in {file} at line {lineno}: {error}',
        file => $file,
        lineno => 4,
        error => __x(
            '"{name}" is a reserved name',
            name => '@' . $reserved,
        ),
    ), qq{And the \@$reserved error message should be correct};
    is sorted, 0, "Should have sorted \@$reserved changes nonce";
}

# Try a plan with a change name that looks like a sha1 hash.
my $sha1 = '6c2f28d125aff1deea615f8de774599acf39a7a1';
$file = file qw(t plans sha1.plan);
$fh = IO::File->new(\"$prags$sha1 $tsnp", '<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with SHA1 change name';
is $@->ident, 'parse', 'The SHA1 error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 4,
    error => __x(
        '"{name}" is invalid because it could be confused with a SHA1 ID',
        name => $sha1,
    ),
), 'And the SHA1 error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with a tag but no change.
$file = file qw(t plans tag-no-change.plan);
$fh = IO::File->new(\"$prags\@foo $tsnp\nbar $tsnp", '<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with tag but no preceding change';
is $@->ident, 'parse', 'The missing change error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 4,
    error => __x(
        'Tag "{tag}" declared without a preceding change',
        tag => 'foo',
    ),
), 'And the missing change error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
$fh = $file->open('<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with dupe tag';
is $@->ident, 'parse', 'The dupe tag error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 12,
    error => __x(
        'Tag "{tag}" duplicates earlier declaration on line {line}',
        tag  => 'bar',
        line => 7,
    ),
), 'And the missing change error message should be correct';
is sorted, 2, 'Should have sorted changes twice';

# Try a plan with a duplicate change within a tag section.
$file = file qw(t plans dupe-change.plan);
$fh = $file->open('<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on plan with dupe change';
is $@->ident, 'parse', 'The dupe change error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 9,
    error => __x(
        'Change "{change}" duplicates earlier declaration on line {line}',
        change  => 'greets',
        line    => 7,
    ),
), 'And the dupe change error message should be correct';
is sorted, 1, 'Should have sorted changes once';

# Try a plan with an invalid requirement.
$fh = IO::File->new(\"\%project=foo\n\nfoo [^bar] $tsnp", '<:utf8_strict');
throws_ok { $plan->_parse('badreq', $fh ) } 'App::Sqitch::X',
    'Should die on invalid dependency';
is $@->ident, 'parse', 'The invalid dependency error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => 'badreq',
    lineno => 3,
    error => __x(
        '"{dep}" is not a valid dependency specification',
        dep => '^bar',
    ),
), 'And the invalid dependency error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with duplicate requirements.
$fh = IO::File->new(\"\%project=foo\n\nfoo [bar baz bar] $tsnp", '<:utf8_strict');
throws_ok { $plan->_parse('dupedep', $fh ) } 'App::Sqitch::X',
    'Should die on dupe dependency';
is $@->ident, 'parse', 'The dupe dependency error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => 'dupedep',
    lineno => 3,
    error => __x(
        'Duplicate dependency "{dep}"',
        dep => 'bar',
    ),
), 'And the dupe dependency error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan without a timestamp.
$file = file qw(t plans no-timestamp.plan);
$fh = IO::File->new(\"${prags}foo hi <t\@heo.ry>", '<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no timestamp';
is $@->ident, 'parse', 'The missing timestamp error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 4,
    error => __ 'Missing timestamp',
), 'And the missing timestamp error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan without a planner.
$file = file qw(t plans no-planner.plan);
$fh = IO::File->new(\"${prags}foo 2012-07-16T23:12:34Z", '<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no planner';
is $@->ident, 'parse', 'The missing parsener error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 4,
    error => __ 'Missing planner name and email',
), 'And the missing planner error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with neither timestamp nor planner.
$file = file qw(t plans no-timestamp-or-planner.plan);
$fh = IO::File->new(\"%project=foo\n\nfoo", '<:utf8_strict');
throws_ok { $plan->_parse($file, $fh) } 'App::Sqitch::X',
    'Should die on change with no timestamp or planner';
is $@->ident, 'parse', 'The missing timestamp or parsener error ident should be "parse"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 3,
    error => __ 'Missing timestamp and planner name and email',
), 'And the missing timestamp or planner error message should be correct';
is sorted, 0, 'Should have sorted changes nonce';

# Try a plan with pragmas.
$file = file qw(t plans pragmas.plan);
$fh = $file->open('<:utf8_strict');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with pragmas"';
is sorted, 1, 'Should have sorted changes once';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    foo            => 'bar',
    project        => 'pragmata',
    uri            => 'https://github.com/sqitchers/sqitch/',
    strict         => 1,
}, 'Should have captured all of the pragmas';
cmp_deeply $parsed, {
    changes => [
        clear,
        change { name => 'hey' },
        change { name => 'you' },
    ],
    lines => [
        clear,
        prag( '', ' ', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION),
        prag( '  ', '', 'foo', ' ', '=', ' ', 'bar', '    ', 'lolz'),
        prag( '', ' ', 'project', '', '=', '', 'pragmata'),
        prag( '', ' ', 'uri', '', '=', '', 'https://github.com/sqitchers/sqitch/'),
        prag( '', ' ', 'strict'),
        blank(),
        change { name => 'hey' },
        change { name => 'you' },
        blank(),
    ],
}, 'Should have "multi.plan" lines and changes';

# Try a plan with deploy/revert operators.
$file = file qw(t plans deploy-and-revert.plan);
$fh = $file->open('<:utf8_strict');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with deploy and revert operators';
is sorted, 2, 'Should have sorted changes twice';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    project        => 'deploy_and_revert',
}, 'Should have captured the deploy-and-revert pragmas';

cmp_deeply $parsed, {
    changes => [
        clear,
        change { name => 'hey', op => '+' },
        change { name => 'you', op => '+' },
        change { name => 'dr_evil', op => '+  ', lspace => ' ' },
        tag    { name => 'foo' },
        change { name => 'this/rocks', op => '+', pspace => '  ' },
        change { name => 'hey-there', lspace => ' ' },
        change {
            name   => 'dr_evil',
            note   => 'revert!',
            op     => '-',
            rspace => ' ',
            pspace => '  ',
            rtag   => [qw(dr_evil)],
        },
        tag    { name => 'bar', lspace => ' ' },
    ],
    lines => [
        clear,
        version,
        prag( '', '', 'project', '', '=', '', 'deploy_and_revert'),
        blank,
        change { name => 'hey', op => '+' },
        change { name => 'you', op => '+' },
        change { name => 'dr_evil', op => '+  ', lspace => ' ' },
        tag    { name => 'foo', ret => 1 },
        blank( '   '),
        change { name => 'this/rocks', op => '+', pspace => '  ' },
        change { name => 'hey-there', lspace => ' ' },
        change {
            name   => 'dr_evil',
            note   => 'revert!',
            op     => '-',
            rspace => ' ',
            pspace => '  ',
            rtag   => [qw(dr_evil)],
        },
        tag    { name => 'bar', lspace => ' ', ret => 1 },
    ],
}, 'Should have "deploy-and-revert.plan" lines and changes';

# Try a non-existent plan file with load().
$file = file qw(t hi nonexistent.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
throws_ok { App::Sqitch::Plan->new(sqitch => $sqitch, target => $target)->load } 'App::Sqitch::X',
    'Should get exception for nonexistent plan file';
is $@->ident, 'plan', 'Nonexistent plan file ident should be "plan"';
is $@->message, __x(
    'Plan file {file} does not exist',
    file => $file,
), 'Nonexistent plan file message should be correct';

# Try a plan with dependencies.
$file = file qw(t plans dependencies.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target), $CLASS,
    'Plan with sqitch with plan file with dependencies';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
ok $parsed = $plan->load, 'Load plan with dependencies file';
is_deeply $parsed->{changes}, [
    clear,
    change { name => 'roles', op => '+' },
    change { name => 'users', op => '+', pspace => '    ', requires => ['roles'] },
    change { name => 'add_user', op => '+', pspace => ' ', requires => [qw(users roles)] },
    change { name => 'dr_evil', op => '+' },
    tag    { name => 'alpha' },
    change {
        name     => 'users',
        op       => '+',
        pspace   => ' ',
        requires => ['users@alpha'],
        rtag     => [qw(dr_evil add_user users)],
    },
    change { name => 'dr_evil', op => '-', rtag => [qw(dr_evil)] },
    change {
        name      => 'del_user',
        op        => '+',
        pspace    => ' ',
        requires  => ['users'],
        conflicts => ['dr_evil']
    },
], 'The changes should include the dependencies';
is sorted, 2, 'Should have sorted changes twice';

# Try a plan with cross-project dependencies.
$file = file qw(t plans project_deps.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target), $CLASS,
    'Plan with sqitch with plan file with project deps';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
ok $parsed = $plan->load, 'Load plan with project deps file';
is_deeply $parsed->{changes}, [
    clear,
    change { name => 'roles', op => '+' },
    change { name => 'users', op => '+', pspace => '    ', requires => ['roles'] },
    change { name => 'add_user', op => '+', pspace => ' ', requires => [qw(users roles log:logger)] },
    change { name => 'dr_evil', op => '+' },
    tag    { name => 'alpha' },
    change {
        name     => 'users',
        op       => '+',
        pspace   => ' ',
        requires => ['users@alpha'],
        rtag     => [qw(dr_evil add_user users)],
    },
    change { name => 'dr_evil', op => '-', rtag => [qw(dr_evil)] },

    change {
        name      => 'del_user',
        op        => '+',
        pspace    => ' ',
        requires  => ['users', 'log:logger@beta1'],
        conflicts => ['dr_evil']
    },
], 'The changes should include the cross-project deps';
is sorted, 2, 'Should have sorted changes twice';

# Should fail with dependencies on tags.
$file = file qw(t plans tag_dependencies.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
$fh = IO::File->new(\"%project=tagdep\n\nfoo $tsnp\n\@bar [:foo] $tsnp", '<:utf8_strict');
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target),
    $CLASS, 'Plan with sqitch with plan with tag dependencies';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
throws_ok { $plan->_parse($file, $fh) }  'App::Sqitch::X',
    'Should get an exception for tag with dependencies';
is $@->ident, 'parse', 'The tag dependencies error ident should be "plan"';
is $@->message, __x(
    'Syntax error in {file} at line {lineno}: {error}',
    file => $file,
    lineno => 4,
    error => __ 'Tags may not specify dependencies',
), 'And the tag dependencies error message should be correct';

# Make sure that lines() loads the plan.
$file = file qw(t plans multi.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target), $CLASS,
    'Plan with sqitch with plan file';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
cmp_deeply [$plan->lines], [
    clear,
    version,
    prag( '', '', 'project', '', '=', '', 'multi'),
    blank('', 'This is a note'),
    blank(),
    blank('', 'And there was a blank line.'),
    blank(),
    change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
    change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
    tag {
        ret           => 1,
        name          => 'foo',
        note          => 'look, a tag!',
        ts            => '2012-07-16T17:24:07',
        rspace        => ' ',
        planner_name  => 'julie',
        planner_email => 'j@ul.ie',
    },
    blank('   '),
    change { name => 'this/rocks', pspace => '  ' },
    change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
    tag { name =>, 'bar', ret => 1 },
    tag { name => 'baz', ret => 1 },
], 'Lines should be parsed from file';

$vivify = 1;
cmp_deeply [$plan->changes], [
    clear,
    change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
    change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
    tag {
        name          => 'foo',
        note          => 'look, a tag!',
        ts            => '2012-07-16T17:24:07',
        rspace        => ' ',
        planner_name  => 'julie',
        planner_email => 'j@ul.ie',
    },
    change { name => 'this/rocks', pspace => '  ' },
    change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
    tag { name =>, 'bar' },
    tag { name => 'baz' },
], 'Changes should be parsed from file';

clear;
change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' };
change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' };

my $foo_tag = tag {
    ret           => 1,
    name          => 'foo',
    note          => 'look, a tag!',
    ts            => '2012-07-16T17:24:07',
    rspace        => ' ',
    planner_name  => 'julie',
    planner_email => 'j@ul.ie',
};

change { name => 'this/rocks', pspace => '  ' };
change { name => 'hey-there', rspace => ' ', note => 'trailing note!' };
cmp_deeply [$plan->tags], [
    $foo_tag,
    tag { name =>, 'bar', ret => 1 },
    tag { name => 'baz', ret => 1 },
], 'Should get all tags from tags()';
is sorted, 2, 'Should have sorted changes twice';

ok $parsed = $plan->load, 'Load should parse plan from file';
cmp_deeply delete $parsed->{pragmas}, {
    syntax_version => App::Sqitch::Plan::SYNTAX_VERSION,
    project        => 'multi',
}, 'Should have captured the multi pragmas';
$vivify = 0;
cmp_deeply $parsed, {
    lines => [
        clear,
        version,
        prag( '', '', 'project', '', '=', '', 'multi'),
        blank('', 'This is a note'),
        blank(),
        blank('', 'And there was a blank line.'),
        blank(),
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            ret           => 1,
            name          => 'foo',
            note          => 'look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        blank('   '),
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
        tag { name =>, 'bar', ret => 1 },
        tag { name => 'baz', ret => 1 },
    ],
    changes => [
        clear,
        change { name => 'hey', planner_name => 'theory', planner_email => 't@heo.ry' },
        change { name => 'you', planner_name => 'anna',   planner_email => 'a@n.na' },
        tag {
            name          => 'foo',
            note          => 'look, a tag!',
            ts            => '2012-07-16T17:24:07',
            rspace        => ' ',
            planner_name  => 'julie',
            planner_email => 'j@ul.ie',
        },
        change { name => 'this/rocks', pspace => '  ' },
        change { name => 'hey-there', note => 'trailing note!', rspace => ' ' },
        tag { name =>, 'bar' },
        tag { name => 'baz' },
    ],
}, 'And the parsed file should have lines and changes';
is sorted, 2, 'Should have sorted changes twice';

##############################################################################
# Test the interator interface.
can_ok $plan, qw(
    index_of
    contains
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
ok $plan->contains($change->name), 'Plan should contain change';
is $plan->get($change->name), $change, 'Should be able to get change 0 by name';
is $plan->find($change->name), $change, 'Should be able to find change 0 by name';
is $plan->get($change->id), $change, 'Should be able to get change 0 by ID';
is $plan->find($change->id), $change, 'Should be able to find change 0 by ID';
is $plan->index_of('@bar'), 3, 'Index of @bar should be 3';
ok $plan->contains('@bar'), 'Plan should contain @bar';
is $plan->get('@bar'), $fourth, 'Should be able to get hey-there via @bar';
is $plan->get($fourth->id), $fourth, 'Should be able to get hey-there via @bar ID';
is $plan->find('@bar'), $fourth, 'Should be able to find hey-there via @bar';
is $plan->find($fourth->id), $fourth, 'Should be able to find hey-there via @bar ID';
ok $plan->seek('@bar'), 'Seek to the "@bar" change';
is $plan->position, 3, 'Position should be at 3 again';
is $plan->current, $fourth, 'Current should be fourth again';
is $plan->index_of('you'), 1, 'Index of you should be 1';
ok $plan->contains('you'), 'Plan should contain "you"';
is $plan->get('you'), $next, 'Should be able to get change 1 by name';
is $plan->find('you'), $next, 'Should be able to find change 1 by name';
ok $plan->seek('you'), 'Seek to the "you" change';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';
is $plan->index_of('baz'), undef, 'Index of baz should be undef';
ok !$plan->contains('baz'), 'Plan should not contain "baz"';
is $plan->index_of('@baz'), 3, 'Index of @baz should be 3';
ok $plan->contains('@baz'), 'Plan should contain @baz';
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
# Let's try searching changes.
isa_ok my $iter = $plan->search_changes, 'CODE',
    'search_changes() should return a code ref';

my $get_all_names = sub {
    my $iter = shift;
    my @res;
    while (my $change = $iter->()) {
        push @res => $change->name;
    }
    return \@res;
};

is_deeply $get_all_names->($iter), [qw(hey you this/rocks hey-there)],
    'All the changes should be returned in the proper order';

# Try reverse order.
is_deeply $get_all_names->( $plan->search_changes( direction => 'DESC' ) ),
    [qw(hey-there this/rocks you hey)], 'Direction "DESC" should work';

# Try invalid directions.
throws_ok { $plan->search_changes( direction => 'foo' ) } 'App::Sqitch::X',
    'Should get error for invalid direction';
is $@->ident, 'DEV', 'Invalid direction error ident should be "DEV"';
is $@->message, 'Search direction must be either "ASC" or "DESC"',
    'Invalid direction error message should be correct';

# Try ascending lowercased.
is_deeply $get_all_names->( $plan->search_changes( direction => 'asc' ) ),
    [qw(hey you this/rocks hey-there)], 'Direction "asc" should work';

# Try change name.
is_deeply $get_all_names->( $plan->search_changes( name => 'you')),
    [qw(you)], 'Search by change name should work';

is_deeply $get_all_names->( $plan->search_changes( name => 'hey')),
    [qw(hey hey-there)], 'Search by change name should work as a regex';

is_deeply $get_all_names->( $plan->search_changes( name => '[-/]')),
    [qw(this/rocks hey-there)],
    'Search by change name should with a character class';

# Try planner name.
is_deeply $get_all_names->( $plan->search_changes( planner => 'Barack' ) ),
    [qw(this/rocks hey-there)], 'Search by planner should work';

is_deeply $get_all_names->( $plan->search_changes( planner => 'a..a' ) ),
    [qw(you)], 'Search by planner should work as a regex';

# Search by operation.
is_deeply $get_all_names->( $plan->search_changes( operation => 'deploy' ) ),
    [qw(hey you this/rocks hey-there)], 'Search by operation "deploy" should work';

is_deeply $get_all_names->( $plan->search_changes( operation => 'revert' ) ),
    [], 'Search by operation "rever" should return nothing';

# Fake out an operation.
my $mock_change = Test::MockModule->new('App::Sqitch::Plan::Change');
$mock_change->mock( operator => sub { return shift->name =~ /hey/ ? '-' : '+' });

is_deeply $get_all_names->( $plan->search_changes( operation => 'DEPLOY' ) ),
    [qw(you this/rocks)], 'Search by operation "DEPLOY" should now return two changes';

is_deeply $get_all_names->( $plan->search_changes( operation => 'REVERT' ) ),
    [qw(hey hey-there)], 'Search by operation "REVERT" should return the other two';

$mock_change->unmock_all;

# Make sure we test only for legal operations.
throws_ok { $plan->search_changes( operation => 'foo' ) } 'App::Sqitch::X',
    'Should get an error for unknown operation';
is $@->ident, 'DEV', 'Unknown operation error ident should be "DEV"';
is $@->message, 'Unknown change operation "foo"',
    'Unknown operation error message should be correct';

# Test offset and limit.
is_deeply $get_all_names->( $plan->search_changes( offset => 2 ) ),
    [qw(this/rocks hey-there)], 'Search with offset 2 should work';

is_deeply $get_all_names->( $plan->search_changes( offset => 2, limit => 1 ) ),
    [qw(this/rocks)], 'Search with offset 2, limit 1 should work';

is_deeply $get_all_names->( $plan->search_changes( offset => 3, direction => 'desc' ) ),
    [qw(hey)], 'Search with offset 3 and direction "desc" should work';

is_deeply $get_all_names->( $plan->search_changes( offset => 2, limit => 1, direction => 'desc' ) ),
    [qw(you)], 'Search with offset 2, limit 1, direction "desc" should work';

is_deeply $get_all_names->( $plan->search_changes( limit => 3, direction => 'desc' ) ),
    [qw(hey-there this/rocks you)], 'Search with limit 3, direction "desc" should work';

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
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . $file->slurp(iomode => '<:utf8_strict'),
    'The contents should look right';

# Make sure it will start from a certain point.
ok $plan->write_to($to, 'this/rocks'), 'Write out the file from "this/rocks"';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=multi' . "\n"
    . '# This is a note' . "\n"
    . "\n"
    . $plan->find('this/rocks')->as_string . "\n"
    . $plan->find('hey-there')->as_string . "\n"
    . join( "\n", map { $_->as_string } $plan->find('hey-there')->tags ) . "\n",
    'Plan should have been written from "this/rocks" through tags at end';

# Make sure it ends at a certain point.
ok $plan->write_to($to, undef, 'you'), 'Write the file up to "you"';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=multi' . "\n"
    . '# This is a note' . "\n"
    . "\n"
    . '# And there was a blank line.' . "\n"
    . "\n"
    . $plan->find('hey')->as_string . "\n"
    . $plan->find('you')->as_string . "\n"
    . join( "\n", map { $_->as_string } $plan->find('you')->tags ) . "\n",
    'Plan should have been written through "you" and its tags';

# Try both.
ok $plan->write_to($to, '@foo', 'this/rocks'),
    'Write from "@foo" to "this/rocks"';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=multi' . "\n"
    . '# This is a note' . "\n"
    . "\n"
    . $plan->find('you')->as_string . "\n"
    . join( "\n", map { $_->as_string } $plan->find('you')->tags ) . "\n"
    . '   ' . "\n"
    . $plan->find('this/rocks')->as_string . "\n",
    'Plan should have been written from "@foo" to "this/rocks"';

# End with a tag.
ok $plan->write_to($to, 'hey', '@foo'), 'Write from "hey" to "@foo"';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . '%project=multi' . "\n"
    . '# This is a note' . "\n"
    . "\n"
    . $plan->find('hey')->as_string . "\n"
    . $plan->find('you')->as_string . "\n"
    . join( "\n", map { $_->as_string } $plan->find('you')->tags ) . "\n",
    'Plan should have been written from "hey" through "@foo"';

##############################################################################
# Test _is_valid.
can_ok $plan, '_is_valid';

for my $name (@bad_names) {
    throws_ok { $plan->_is_valid( tag => $name) } 'App::Sqitch::X',
        qq{Should find "$name" invalid};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: tags must not begin with punctuation, }
        . 'contain "@", ":", "#", or blanks, or end in punctuation or digits following punctuation',
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
    'v1.2-1',  # version number with dash
    'v1.2+1',  # version number with plus
    'v1.2_1',  # version number with underscore
) {
    local $ENV{FOO} = 1;
    my $disp = Encode::encode_utf8($name);
    ok $plan->_is_valid(change => $name), qq{Name "$disp" should be valid};
}

##############################################################################
# Try adding a tag.
ok my $tag = $plan->tag( name => 'w00t' ), 'Add tag "w00t"';
is $plan->count, 4, 'Should have 4 changes';
ok $plan->contains('@w00t'), 'Should find "@w00t" in plan';
is $plan->index_of('@w00t'), 3, 'Should find "@w00t" at index 3';
is $plan->last->name, 'hey-there', 'Last change should be "hey-there"';
is_deeply [map { $_->name } $plan->last->tags], [qw(bar baz w00t)],
    'The w00t tag should be on the last change';
isa_ok $tag, 'App::Sqitch::Plan::Tag';
is $tag->name, 'w00t', 'The returned tag should be @w00t';
is $tag->change, $plan->last, 'The @w00t change should be the last change';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . $file->slurp(iomode => '<:utf8_strict')
    . $tag->as_string . "\n",
    { encoding => 'UTF-8' },
    'The contents should include the "w00t" tag';
# Try passing the tag name with a leading @.
ok my $tag2 = $plan->tag( name => '@alpha' ), 'Add tag "@alpha"';
ok $plan->contains('@alpha'), 'Should find "@alpha" in plan';
is $plan->index_of('@alpha'), 3, 'Should find "@alpha" at index 3';
is $tag2->name, 'alpha', 'The returned tag should be @alpha';
is $tag2->change, $plan->last, 'The @alpha change should be the last change';

# Try specifying the change to tag.
ok my $tag3 = $plan->tag(name => 'blarney', change => 'you'),
    'Tag change "you"';
is $plan->count, 4, 'Should still have 4 changes';
ok $plan->contains('@blarney'), 'Should find "@blarney" in plan';
is $plan->index_of('@blarney'), 1, 'Should find "@blarney" at index 1';
is_deeply [map { $_->name } $plan->change_at(1)->tags], [qw(foo blarney)],
    'The blarney tag should be on the second change';
isa_ok $tag3, 'App::Sqitch::Plan::Tag';
is $tag3->name, 'blarney', 'The returned tag should be @blarney';
is $tag3->change, $plan->change_at(1), 'The @blarney change should be the second change';

# Should choke on a duplicate tag.
throws_ok { $plan->tag( name => 'w00t' ) } 'App::Sqitch::X',
    'Should get error trying to add duplicate tag';
is $@->ident, 'plan', 'Duplicate tag error ident should be "plan"';
is $@->message, __x(
    'Tag "{tag}" already exists',
    tag => '@w00t',
), 'And the error message should report it as a dupe';

# Should choke on an invalid tag names.
for my $name (@bad_names, 'foo#bar') {
    next if $name =~ /^@/;
    throws_ok { $plan->tag( name => $name ) } 'App::Sqitch::X',
        qq{Should get error for invalid tag "$name"};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: tags must not begin with punctuation, }
        . 'contain "@", ":", "#", or blanks, or end in punctuation or digits following punctuation',
        name => $name,
    ), qq{And the "$name" error message should be correct};
}

# Validate reserved names.
for my $reserved (qw(HEAD ROOT)) {
    throws_ok { $plan->tag( name => $reserved ) } 'App::Sqitch::X',
        qq{Should get error for reserved tag "$reserved"};
    is $@->ident, 'plan', qq{Reserved tag "$reserved" error ident should be "plan"};
    is $@->message, __x(
        '"{name}" is a reserved name',
        name => $reserved,
    ), qq{And the reserved tag "$reserved" message should be correct};
}

throws_ok { $plan->tag( name => $sha1 ) } 'App::Sqitch::X',
    'Should get error for a SHA1 tag';
is $@->ident, 'plan', 'SHA1 tag error ident should be "plan"';
is $@->message, __x(
    '"{name}" is invalid because it could be confused with a SHA1 ID',
    name => $sha1,,
), 'And the reserved name error should be output';

##############################################################################
# Try adding a change.
ok my $new_change = $plan->add(name => 'booyah', note => 'Hi there'),
    'Add change "booyah"';
is $plan->count, 5, 'Should have 5 changes';
ok $plan->contains('booyah'), 'Should find "booyah" in plan';
is $plan->index_of('booyah'), 4, 'Should find "booyah" at index 4';
is $plan->last->name, 'booyah', 'Last change should be "booyah"';
isa_ok $new_change, 'App::Sqitch::Plan::Change';
is $new_change->as_string, join (' ',
    'booyah',
    $new_change->timestamp->as_string,
    $new_change->format_planner,
    $new_change->format_note,
), 'Should have plain stringification of "booya"';

my $contents = $file->slurp(iomode => '<:utf8_strict');
$contents =~ s{(\s+this/rocks)}{"\n" . $tag3->as_string . $1}ems;
ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . "\n"
    . $contents
    . $tag->as_string . "\n"
    . $tag2->as_string . "\n\n"
    . $new_change->as_string . "\n",
    { encoding => 'UTF-8' },
    'The contents should include the "booyah" change';

# Make sure dependencies are verified.
ok $new_change = $plan->add(name => 'blow', requires => ['booyah']),
    'Add change "blow"';
is $plan->count, 6, 'Should have 6 changes';
ok $plan->contains('blow'), 'Should find "blow" in plan';
is $plan->index_of('blow'), 5, 'Should find "blow" at index 5';
is $plan->last->name, 'blow', 'Last change should be "blow"';
is $new_change->as_string,
    'blow [booyah] ' . $new_change->timestamp->as_string . ' '
    . $new_change->format_planner,
    'Should have nice stringification of "blow [booyah]"';
is [$plan->lines]->[-1], $new_change,
    'The new change should have been appended to the lines, too';

# Make sure dependencies are unique.
ok $new_change = $plan->add(name => 'jive', requires => [qw(blow blow)]),
    'Add change "jive" with dupe dependency';
is $plan->count, 7, 'Should have 7 changes';
ok $plan->contains('jive'), 'Should find "jive" in plan';
is $plan->index_of('jive'), 6, 'Should find "jive" at index 6';
is $plan->last->name, 'jive', 'jive change should be "jive"';
is_deeply [ map { $_->change } $new_change->requires ], ['blow'],
    'Should have dependency "blow"';
is $new_change->as_string,
    'jive [blow] ' . $new_change->timestamp->as_string . ' '
    . $new_change->format_planner,
    'Should have nice stringification of "jive [blow]"';
is [$plan->lines]->[-1], $new_change,
    'The new change should have been appended to the lines, too';

# Make sure externals and conflicts are unique.
ok $new_change = $plan->add(
    name => 'moo',
    requires => [qw(ext:foo ext:foo)],
    conflicts => [qw(blow blow ext:whu ext:whu)],
),  'Add change "moo" with dupe dependencies';

is $plan->count, 8, 'Should have 8 changes';
ok $plan->contains('moo'), 'Should find "moo" in plan';
is $plan->index_of('moo'), 7, 'Should find "moo" at index 7';
is $plan->last->name, 'moo', 'moo change should be "moo"';
is_deeply [ map { $_->as_string } $new_change->requires ], ['ext:foo'],
    'Should require "ext:whu"';
is_deeply [ map { $_->as_string } $new_change->conflicts ], [qw(blow ext:whu)],
    'Should conflict with "blow" and "ext:whu"';
is $new_change->as_string,
    'moo [ext:foo !blow !ext:whu] ' . $new_change->timestamp->as_string . ' '
    . $new_change->format_planner,
    'Should have nice stringification of "moo [ext:foo !blow !ext:whu]"';
is [$plan->lines]->[-1], $new_change,
    'The new change should have been appended to the lines, too';

# Should choke on a duplicate change.
throws_ok { $plan->add(name => 'blow') } 'App::Sqitch::X',
    'Should get error trying to add duplicate change';
is $@->ident, 'plan', 'Duplicate change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" already exists in plan {file}.\nUse "sqitch rework" to copy and rework it},
    change => 'blow',
    file   => $plan->file,
), 'And the error message should suggest "rework"';

# Should choke on an invalid change names.
for my $name (@bad_names) {
    throws_ok { $plan->add( name => $name ) } 'App::Sqitch::X',
        qq{Should get error for invalid change "$name"};
    is $@->ident, 'plan', qq{Invalid name "$name" error ident should be "plan"};
    is $@->message, __x(
        qq{"{name}" is invalid: changes must not begin with punctuation, }
        . 'contain "@", ":", "#", or blanks, or end in punctuation or digits following punctuation',
        name => $name,
    ), qq{And the "$name" error message should be correct};
}

# Try a reserved name.
for my $reserved (qw(HEAD ROOT)) {
    throws_ok { $plan->add( name => $reserved ) } 'App::Sqitch::X',
        qq{Should get error for reserved name "$reserved"};
    is $@->ident, 'plan', qq{Reserved name "$reserved" error ident should be "plan"};
    is $@->message, __x(
        '"{name}" is a reserved name',
        name => $reserved,
    ), qq{And the reserved name "$reserved" message should be correct};
}

# Try an unknown dependency.
throws_ok { $plan->add( name => 'whu', requires => ['nonesuch' ] ) } 'App::Sqitch::X',
    'Should get failure for failed dependency';
is $@->ident, 'plan', 'Dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot add change "{change}": requires unknown change "{req}"',
    change => 'whu',
    req    => 'nonesuch',
), 'The dependency error should be correct';

# Try invalid dependencies.
throws_ok { $plan->add( name => 'whu', requires => ['^bogus' ] ) } 'App::Sqitch::X',
    'Should get failure for invalid dependency';
is $@->ident, 'plan', 'Invalid dependency error ident should be "plan"';
is $@->message, __x(
    '"{dep}" is not a valid dependency specification',
    dep => '^bogus',
), 'The invalid dependency error should be correct';

throws_ok { $plan->add( name => 'whu', conflicts => ['^bogus' ] ) } 'App::Sqitch::X',
    'Should get failure for invalid conflict';
is $@->ident, 'plan', 'Invalid conflict error ident should be "plan"';
is $@->message, __x(
    '"{dep}" is not a valid dependency specification',
    dep => '^bogus',
), 'The invalid conflict error should be correct';

# Should choke on an unknown tag, too.
throws_ok { $plan->add(name => 'whu', requires => ['@nonesuch' ] ) } 'App::Sqitch::X',
    'Should get failure for failed tag dependency';
is $@->ident, 'plan', 'Tag dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot add change "{change}": requires unknown change "{req}"',
    change => 'whu',
    req    => '@nonesuch',
), 'The tag dependency error should be correct';

# Should choke on a change that looks like a SHA1.
throws_ok { $plan->add(name => $sha1) } 'App::Sqitch::X',
    'Should get error for a SHA1 change';
is $@->ident, 'plan', 'SHA1 tag error ident should be "plan"';
is $@->message, __x(
    '"{name}" is invalid because it could be confused with a SHA1 ID',
    name => $sha1,,
), 'And the reserved name error should be output';

##############################################################################
# Try reworking a change.
can_ok $plan, 'rework';
ok my $rev_change = $plan->rework( name => 'you' ), 'Rework change "you"';
isa_ok $rev_change, 'App::Sqitch::Plan::Change';
is $rev_change->name, 'you', 'Reworked change should be "you"';
ok my $orig = $plan->change_at($plan->first_index_of('you')),
    'Get original "you" change';
is $orig->name, 'you', 'It should also be named "you"';
is_deeply [ map { $_->format_name } $orig->rework_tags ],
    [qw(@bar)], 'And it should have the one rework tag';
is $orig->deploy_file, $target->deploy_dir->file('you@bar.sql'),
    'The original file should now be named you@bar.sql';
is $rev_change->as_string,
    'you [you@bar] ' . $rev_change->timestamp->as_string . ' '
    . $rev_change->format_planner,
    'It should require the previous "you" change';
is [$plan->lines]->[-1], $rev_change,
    'The new "you" should have been appended to the lines, too';

# Make sure it was appended to the plan.
ok $plan->contains('you@HEAD'), 'Should find "you@HEAD" in plan';
is $plan->index_of('you@HEAD'), 8, 'It should be at position 8';
is $plan->count, 9, 'The plan count should be 9';

# Tag and add again, to be sure we can do it multiple times.
ok $plan->tag( name => '@beta1' ), 'Tag @beta1';
ok my $rev_change2 = $plan->rework( name => 'you' ),
    'Rework change "you" again';
isa_ok $rev_change2, 'App::Sqitch::Plan::Change';
is $rev_change2->name, 'you', 'New reworked change should be "you"';
ok $orig = $plan->change_at($plan->first_index_of('you')),
    'Get original "you" change again';
is $orig->name, 'you', 'It should still be named "you"';
is_deeply [ map { $_->format_name } $orig->rework_tags ],
    [qw(@bar)], 'And it should have the one rework tag';
ok $rev_change = $plan->get('you@beta1'), 'Get you@beta1';
is $rev_change->name, 'you', 'The second "you" should be named that';
is_deeply [ map { $_->format_name } $rev_change->rework_tags ],
    [qw(@beta1)], 'And the second change should have the rework_tag "@beta1"';
is_deeply [ $rev_change2->rework_tags ],
    [], 'But the new reworked change should have no rework tags';
is $rev_change2->as_string,
    'you [you@beta1] ' . $rev_change2->timestamp->as_string . ' '
    . $rev_change2->format_planner,
    'It should require the previous "you" change';
is [$plan->lines]->[-1], $rev_change2,
    'The new reworking should have been appended to the lines';

# Make sure it was appended to the plan.
ok $plan->contains('you@HEAD'), 'Should find "you@HEAD" in plan';
is $plan->index_of('you@HEAD'), 9, 'It should be at position 9';
is $plan->count, 10, 'The plan count should be 10';

# Try a nonexistent change name.
throws_ok { $plan->rework( name => 'nonexistent' ) } 'App::Sqitch::X',
    'rework should die on nonexistent change';
is $@->ident, 'plan', 'Nonexistent change error ident should be "plan"';
is $@->message, __x(
    qq{Change "{change}" does not exist in {file}.\nUse "sqitch add {change}" to add it to the plan},
    change => 'nonexistent',
    file   => $plan->file,
), 'And the error should suggest "sqitch add"';

# Try reworking without an intervening tag.
throws_ok { $plan->rework( name => 'you' ) } 'App::Sqitch::X',
    'rework_stpe should die on lack of intervening tag';
is $@->ident, 'plan', 'Missing tag error ident should be "plan"';
is $@->message, __x(
    qq{Cannot rework "{change}" without an intervening tag.\nUse "sqitch tag" to create a tag and try again},
    change => 'you',
), 'And the error should suggest "sqitch tag"';

# Make sure it checks dependencies.
throws_ok { $plan->rework( name => 'booyah', requires => ['nonesuch' ] ) }
    'App::Sqitch::X',
    'rework should die on failed dependency';
is $@->ident, 'plan', 'Rework dependency error ident should be "plan"';
is $@->message, __x(
    'Cannot rework change "{change}": requires unknown change "{req}"',
    change => 'booyah',
    req    => 'nonesuch',
), 'The rework dependency error should be correct';

# Try invalid dependencies.
throws_ok { $plan->rework( name => 'booyah', requires => ['^bogus' ] ) } 'App::Sqitch::X',
    'Should get failure for invalid dependency';
is $@->ident, 'plan', 'Invalid dependency error ident should be "plan"';
is $@->message, __x(
    '"{dep}" is not a valid dependency specification',
    dep => '^bogus',
), 'The invalid dependency error should be correct';

throws_ok { $plan->rework( name => 'booyah', conflicts => ['^bogus' ] ) } 'App::Sqitch::X',
    'Should get failure for invalid conflict';
is $@->ident, 'plan', 'Invalid conflict error ident should be "plan"';
is $@->message, __x(
    '"{dep}" is not a valid dependency specification',
    dep => '^bogus',
), 'The invalid conflict error should be correct';

##############################################################################
# Try a plan with a duplicate change in different tag sections.
$file = file qw(t plans dupe-change-diff-tag.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target),
    $CLASS, 'Plan shoud work plan with dupe change across tags';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
is $plan->project, 'dupe_change_diff_tag', 'Project name should be set';
cmp_deeply [ $plan->lines ], [
    clear,
    version,
    prag( '', '', 'project', '', '=', '', 'dupe_change_diff_tag'),
    blank,
    change { name => 'whatever' },
    tag    { name => 'foo', ret => 1 },
    blank(),
    change { name => 'hi' },
    tag    { name => 'bar', ret => 1 },
    blank(),
    change { name => 'greets' },
    change { name => 'whatever', rtag => [qw(hi whatever)] },
], 'Lines with dupe change should be read from file';

$vivify = 1;
cmp_deeply [ $plan->changes ], [
    clear,
    change { name => 'whatever' },
    tag    { name => 'foo' },
    change { name => 'hi' },
    tag    { name => 'bar' },
    change { name => 'greets' },
    change { name => 'whatever', rtag => [qw(hi whatever)] },
], 'Noes with dupe change should be read from file';
is sorted, 3, 'Should have sorted changes three times';

# Try to find whatever.
ok $plan->contains('whatever'), 'Should find "whatever" in plan';
throws_ok { $plan->index_of('whatever') } 'App::Sqitch::X',
    'Should get an error trying to find dupe key.';
is $@->ident, 'plan', 'Dupe key error ident should be "plan"';
is $@->message, __ 'Change lookup failed',
    'Dupe key error message should be correct';
is_deeply +MockOutput->get_vent, [
    [__x(
        'Change "{change}" is ambiguous. Please specify a tag-qualified change:',
        change => 'whatever',
    )],
    [ '  * ', 'whatever@HEAD' ],
    [ '  * ', 'whatever@foo' ],
], 'Should have output listing tag-qualified changes';

is $plan->index_of('whatever@HEAD'), 3, 'Should get 3 for whatever@HEAD';
is $plan->index_of('whatever@bar'), 0, 'Should get 0 for whatever@bar';

# Make sure seek works, too.
throws_ok { $plan->seek('whatever') } 'App::Sqitch::X',
    'Should get an error seeking dupe key.';
is $@->ident, 'plan', 'Dupe key error ident should be "plan"';
is $@->message, __ 'Change lookup failed',
    'Dupe key error message should be correct';
is_deeply +MockOutput->get_vent, [
    [__x(
        'Change "{change}" is ambiguous. Please specify a tag-qualified change:',
        change => 'whatever',
    )],
    [ '  * ', 'whatever@HEAD' ],
    [ '  * ', 'whatever@foo' ],
], 'Should have output listing tag-qualified changes';

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

# Make sure it dies on an invalid file.
throws_ok { $plan->open_script(file 'nonexistent' ) } 'App::Sqitch::X',
    'open_script() should die on nonexistent file';
is $@->ident, 'io', 'Nonexistent file error ident should be "io"';
is $@->message, __x(
    'Cannot open {file}: {error}',
    file  => 'nonexistent',
    error => $! || 'No such file or directory',
), 'Nonexistent file error message should be correct';

##############################################################################
# Test check_changes()
$mocker->unmock('check_changes');
can_ok $CLASS, 'check_changes';
my @deps;
my $i = 0;
my $j = 0;
$mock_change->mock(requires => sub {
    my $reqs = caller eq 'App::Sqitch::Plan' ? $deps[$i++] : $deps[$j++];
    @{ $reqs->{requires} };
});

sub changes {
    clear;
    $i = $j = 0;
    map {
        change { name => $_ };
    } @_;
}

# Start with no dependencies.
$project = 'foo';
my %ddep = ( requires => [], conflicts => [] );
@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [map { $_->name } $plan->check_changes({}, changes qw(this that other))],
    [qw(this that other)], 'Should get original order when no dependencies';

@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [map { $_->name } $plan->check_changes('foo', changes qw(this that other))],
    [qw(this that other)], 'Should get original order when no prepreqs';

# Have that require this.
@deps = ({%ddep}, {%ddep, requires => [dep 'this']}, {%ddep});
cmp_deeply [map { $_->name }$plan->check_changes('foo', changes qw(this that other))],
    [qw(this that other)], 'Should get original order when that requires this';

# Have other require that.
@deps = ({%ddep}, {%ddep, requires => [dep 'this']}, {%ddep, requires => [dep 'that']});
cmp_deeply [map { $_->name } $plan->check_changes('foo', changes qw(this that other))],
    [qw(this that other)], 'Should get original order when other requires that';

my $deperr = sub {
    join "\n  ", __n(
        'Dependency error detected:',
        'Dependency errors detected:',
        @_
    ), @_
};

# Have this require other.
@deps = ({%ddep, requires => [dep 'other']}, {%ddep}, {%ddep});
throws_ok {
    $plan->check_changes('foo', changes qw(this that other))
} 'App::Sqitch::X', 'Should get error for out-of-order dependency';
is $@->ident, 'parse', 'Unordered dependency error ident should be "parse"';
is $@->message, $deperr->(__nx(
    'Change "{change}" planned {num} change before required change "{required}"',
    'Change "{change}" planned {num} changes before required change "{required}"',
    2,
    change   => 'this',
    required => 'other',
    num      => 2,
) . "\n    " .  __xn(
    'HINT: move "{change}" down {num} line in {plan}',
    'HINT: move "{change}" down {num} lines in {plan}',
    2,
    change => 'this',
    num    => 2,
    plan   => $plan->file,
)),  'And the unordered dependency error message should be correct';

# Have this require other and that.
@deps = ({%ddep, requires => [dep 'other', dep 'that']}, {%ddep}, {%ddep});
throws_ok {
    $plan->check_changes('foo', changes qw(this that other));
} 'App::Sqitch::X', 'Should get error for multiple dependency errors';
is $@->ident, 'parse', 'Multiple dependency error ident should be "parse"';
is $@->message, $deperr->(
    __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        2,
        change   => 'this',
        required => 'other',
        num      => 2,
    ), __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        1,
        change   => 'this',
        required => 'that',
        num      => 1,
    ) . "\n    " .  __xn(
        'HINT: move "{change}" down {num} line in {plan}',
        'HINT: move "{change}" down {num} lines in {plan}',
        2,
        change => 'this',
        num    => 2,
        plan   => $plan->file,
    ),
),  'And the multiple dependency error message should be correct';

# Have that require a tag.
@deps = ({%ddep}, {%ddep, requires => [dep '@howdy']}, {%ddep});
cmp_deeply [$plan->check_changes('foo', {'@howdy' => 2 }, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order when requiring a tag';

# Requires a step as of a tag.
@deps = ({%ddep}, {%ddep, requires => [dep 'foo@howdy']}, {%ddep});
cmp_deeply [$plan->check_changes('foo', {'foo' => 1, '@howdy' => 2 }, changes qw(this that other))],
    [changes qw(this that other)],
    'Should get original order when requiring a step as-of a tag';

# Should die if the step comes *after* the specified tag.
@deps = ({%ddep}, {%ddep, requires => [dep 'foo@howdy']}, {%ddep});
throws_ok { $plan->check_changes('foo', {'foo' => 3, '@howdy' => 2 }, changes qw(this that other)) }
    'App::Sqitch::X', 'Should get failure for a step after a tag';
is $@->ident, 'parse', 'Step after tag error ident should be "parse"';
is $@->message, $deperr->(__x(
    'Unknown change "{required}" required by change "{change}"',
    required => 'foo@howdy',
    change   => 'that',
)),  'And we the unknown change as-of a tag message should be correct';

# Add a cycle.
@deps = ({%ddep, requires => [dep 'that']}, {%ddep, requires => [dep 'this']}, {%ddep});
throws_ok { $plan->check_changes('foo', changes qw(this that other)) } 'App::Sqitch::X',
    'Should get failure for a cycle';
is $@->ident, 'parse', 'Cycle error ident should be "parse"';
is $@->message, $deperr->(
    __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        1,
        change   => 'this',
        required => 'that',
        num      => 1,
    ) . "\n    " .  __xn(
        'HINT: move "{change}" down {num} line in {plan}',
        'HINT: move "{change}" down {num} lines in {plan}',
        1,
        change => 'this',
        num    => 1,
        plan   => $plan->file,
    ),
), 'The cycle error message should be correct';

# Add an extended cycle.
@deps = (
    {%ddep, requires => [dep 'that']},
    {%ddep, requires => [dep 'other']},
    {%ddep, requires => [dep 'this']}
);
throws_ok { $plan->check_changes('foo', changes qw(this that other)) } 'App::Sqitch::X',
    'Should get failure for a two-hop cycle';
is $@->ident, 'parse', 'Two-hope cycle error ident should be "parse"';
is $@->message, $deperr->(
    __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        1,
        change   => 'this',
        required => 'that',
        num      => 1,
    ) . "\n    " .  __xn(
        'HINT: move "{change}" down {num} line in {plan}',
        'HINT: move "{change}" down {num} lines in {plan}',
        1,
        change => 'this',
        num    => 1,
        plan   => $plan->file,
    ), __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        1,
        change   => 'that',
        required => 'other',
        num      => 1,
    ) . "\n    " .  __xn(
        'HINT: move "{change}" down {num} line in {plan}',
        'HINT: move "{change}" down {num} lines in {plan}',
        1,
        change => 'that',
        num    => 1,
        plan   => $plan->file,
    ),
), 'The two-hop cycle error message should be correct';

# Okay, now deal with depedencies from earlier change sections.
@deps = ({%ddep, requires => [dep 'foo']}, {%ddep}, {%ddep});
cmp_deeply [$plan->check_changes('foo', { foo => 1}, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ({%ddep, requires => [dep 'other', dep 'that']}, {%ddep, requires => [dep 'sqitch']}, {%ddep});
throws_ok {
    $plan->check_changes('foo', {sqitch => 1 }, changes qw(this that other))
} 'App::Sqitch::X', 'Should get error with misordered and seen dependencies';
is $@->ident, 'parse', 'Misorderd and seen error ident should be "parse"';
is $@->message, $deperr->(
    __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        2,
        change   => 'this',
        required => 'other',
        num      => 2,
    ), __nx(
        'Change "{change}" planned {num} change before required change "{required}"',
        'Change "{change}" planned {num} changes before required change "{required}"',
        1,
        change   => 'this',
        required => 'that',
        num      => 1,
    ) . "\n    " .  __xn(
        'HINT: move "{change}" down {num} line in {plan}',
        'HINT: move "{change}" down {num} lines in {plan}',
        2,
        change => 'this',
        num    => 2,
        plan   => $plan->file,
    ),
),  'And the misordered and seen error message should be correct';

# Make sure it fails on unknown previous dependencies.
@deps = ({%ddep, requires => [dep 'foo']}, {%ddep}, {%ddep});
throws_ok { $plan->check_changes('foo', changes qw(this that other)) } 'App::Sqitch::X',
    'Should die on unknown dependency';
is $@->ident, 'parse', 'Unknown dependency error ident should be "parse"';
is $@->message, $deperr->(__x(
    'Unknown change "{required}" required by change "{change}"',
    required => 'foo',
    change   => 'this',
)), 'And the error should point to the offending change';

# Okay, now deal with depedencies from earlier change sections.
@deps = ({%ddep, requires => [dep '@foo']}, {%ddep}, {%ddep});
throws_ok { $plan->check_changes('foo', changes qw(this that other)) } 'App::Sqitch::X',
    'Should die on unknown tag dependency';
is $@->ident, 'parse', 'Unknown tag dependency error ident should be "parse"';
is $@->message, $deperr->(__x(
    'Unknown change "{required}" required by change "{change}"',
    required => '@foo',
    change   => 'this',
)), 'And the error should point to the offending change';

# Allow dependencies from different projects.
@deps = ({%ddep}, {%ddep, requires => [dep 'bar:bob']}, {%ddep});
cmp_deeply [$plan->check_changes('foo', changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order with external dependency';
$project = undef;

# Make sure that a change does not require itself
@deps = ({%ddep, requires => [dep 'this']}, {%ddep}, {%ddep});
throws_ok { $plan->check_changes('foo', changes qw(this that other)) } 'App::Sqitch::X',
    'Should die on self dependency';
is $@->ident, 'parse', 'Self dependency error ident should be "parse"';
is $@->message, $deperr->(__x(
    'Change "{change}" cannot require itself',
    change   => 'this',
)), 'And the self dependency error should be correct';

# Make sure sort ordering respects the original ordering.
@deps = (
    {%ddep},
    {%ddep},
    {%ddep, requires => [dep 'that']},
    {%ddep, requires => [dep 'that', dep 'this']},
);
cmp_deeply [$plan->check_changes('foo', changes qw(this that other thing))],
    [changes qw(this that other thing)],
    'Should get original order with cascading dependencies';
$project = undef;

@deps = (
    {%ddep},
    {%ddep},
    {%ddep, requires => [dep 'that']},
    {%ddep, requires => [dep 'that', dep 'this', dep 'other']},
    {%ddep, requires => [dep 'that', dep 'this']},
);
cmp_deeply [$plan->check_changes('foo', changes qw(this that other thing yowza))],
    [changes qw(this that other thing yowza)],
    'Should get original order with multiple cascading dependencies';
$project = undef;

##############################################################################
# Test dependency testing.
can_ok $plan, '_check_dependencies';
$mock_change->unmock('requires');

for my $req (qw(hi greets whatever @foo whatever@foo ext:larry ext:greets)) {
    $change = App::Sqitch::Plan::Change->new(
        plan     => $plan,
        name     => 'lazy',
        requires => [dep $req],
    );
    my $req_proj = $req =~ /:/ ? do {
        (my $p = $req) =~ s/:.+//;
        $p;
    } : $plan->project;
    my ($dep) = $change->requires;
    is $dep->project, $req_proj,
        qq{Depend "$req" should be in project "$req_proj"};
    ok $plan->_check_dependencies($change, 'add'),
        qq{Dependency on "$req" should succeed};
}

for my $req (qw(wanker @blah greets@foo)) {
    $change = App::Sqitch::Plan::Change->new(
        plan     => $plan,
        name     => 'lazy',
        requires => [dep $req],
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

##############################################################################
# Test pragma accessors.
is $plan->uri, undef, 'Should have undef URI when no pragma';
$file = file qw(t plans pragmas.plan);
$target = App::Sqitch::Target->new(sqitch => $sqitch, plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch, target => $target),
    $CLASS, 'Plan with sqitch with plan file with dependencies';
is $plan->file, $target->plan_file, 'File should be coopied from Sqitch';
is $plan->syntax_version, App::Sqitch::Plan::SYNTAX_VERSION,
    'syntax_version should be set';
is $plan->project, 'pragmata', 'Project should be set';
is $plan->uri, URI->new('https://github.com/sqitchers/sqitch/'),
    'Should have URI from pragma';
isa_ok $plan->uri, 'URI', 'It';

# Make sure we get an error if there is no project pragma.
$fh = IO::File->new(\"%strict\n\nfoo $tsnp", '<:utf8_strict');
throws_ok { $plan->_parse('noproject', $fh) } 'App::Sqitch::X',
    'Should die on plan with no project pragma';
is $@->ident, 'parse', 'Missing prorject error ident should be "parse"';
is $@->message, __x('Missing %project pragma in {file}', file => 'noproject'),
    'The missing project error message should be correct';

# Make sure we get an error for an invalid project name.
for my $bad (@bad_names) {
    my $fh = IO::File->new(\"%project=$bad\n\nfoo $tsnp", '<:utf8_strict');
    throws_ok { $plan->_parse(badproj => $fh) } 'App::Sqitch::X',
        qq{Should die on invalid project name "$bad"};
    is $@->ident, 'parse', qq{Ident for bad proj "$bad" should be "parse"};
    my $error =  __x(
            'invalid project name "{project}": project names must not '
            . 'begin with punctuation, contain "@", ":", "#", or blanks, or end in '
            . 'punctuation or digits following punctuation',
            project => $bad);
    is $@->message, __x(
        'Syntax error in {file} at line {lineno}: {error}',
        file => 'badproj',
        lineno => 1,
        error => $error
    ), qq{Error message for bad project "$bad" should be correct};
}

done_testing;
