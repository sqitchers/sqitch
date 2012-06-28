#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More;
use App::Sqitch;
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

sub change {
    my @op = defined $_[4] ? split /([+-])/, $_[4] : ();
    $prev_change = App::Sqitch::Plan::Change->new(
        plan      => $plan,
        lspace    => $_[0] // '',
        name      => $_[1],
        rspace    => $_[2] // '',
        comment   => $_[3] // '',
        lopspace  => $op[0] // '',
        operator  => $op[1] // '',
        ropspace  => $op[2] // '',
        pspace    => $_[5] // '',
        requires  => $_[6] // [],
        conflicts => $_[7] // [],
        ($prev_tag ? (since_tag => $prev_tag) : ()),
    );
    if (my $duped = $seen{$_[1]}) {
        $duped->suffix($prev_tag->format_name);
    }
    $seen{$_[1]} = $prev_change;
    $prev_change->id;
    $prev_change->tags;
    return $prev_change;
}

sub tag {
    $prev_tag = App::Sqitch::Plan::Tag->new(
        plan    => $plan,
        change    => $prev_change,
        lspace  => $_[1] // '',
        name    => $_[2],
        rspace  => $_[3] // '',
        comment => $_[4] // '',
    );
    $prev_change->add_tag($prev_tag);
    $prev_tag->id;
    return () unless $_[0];
    return $prev_tag;
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
    change(  '', 'hey'),
    change(  '', 'you'),
    tag(0,   '', 'foo', ' ', ' look, a tag!'),
], 'All "widgets.plan" changes should be parsed';

cmp_deeply [$parsed->{lines}->items], [
    clear,
    version,
    blank('', ' This is a comment'),
    blank(),
    blank(' ', ' And there was a blank line.'),
    blank(),
    change(  '', 'hey'),
    change(  '', 'you'),
    tag(1,   '', 'foo', ' ', ' look, a tag!'),
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
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(0,   '', 'foo', ' ', ' look, a tag!'),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(0,   '', 'bar', ' '),
        tag(0,   '', 'baz', ''),
    ],
    lines => [
        clear,
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(1,   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(1,   '', 'bar', ' '),
        tag(1,   '', 'baz', ''),
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
        change(  '', 'hey'),
        change(  '', 'you'),
        change(  '', 'whatwhatwhat'),
    ],
    changes => [
        clear,
        change(  '', 'hey'),
        change(  '', 'you'),
        change(  '', 'whatwhatwhat'),
    ],
}, 'Should have lines and changes for tagless plan';

# Try a plan with a bad change name.
$file = file qw(t plans bad-change.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with bad change name';
is sorted, 0, 'Should not have sorted changes';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    4,
    qq{: "what" does not look like a dependency.\n},
    qq{Dependencies must begin with ":" or "!" and be valid change names},
]], 'And the error should have been output';

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
        throws_ok { $plan->_parse('baditem', $fh) } qr/FAIL:/,
            qq{Should die on plan with bad name "$line"};
        is sorted, 0, 'Should not have sorted changes';
        cmp_deeply +MockOutput->get_fail, [[
            "Syntax error in baditem at line ",
            1,
            qq{: Invalid $what "$line"; ${what}s must not begin with },
            'punctuation or end in punctuation or digits following punctuation'
        ]], qq{And "$line" should trigger the appropriate error};
    }
}

# Try some valid change and tag names.
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
    my $fh = IO::File->new(\$name, '<:utf8');
    ok my $parsed = $plan->_parse('gooditem', $fh),
        encode_utf8(qq{Should parse "$name"});
    cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
        changes => [ clear, change('', $name) ],
        lines => [ clear, version, change('', $name) ],
    }, encode_utf8(qq{Should have line and change for "$name"});

    # Test a tag name.
    my $tag = '@' . $name;
    my $lines = "foo\n$tag";
    $fh = IO::File->new(\$lines, '<:utf8');
    ok $parsed = $plan->_parse('gooditem', $fh),
        encode_utf8(qq{Should parse "$tag"});
    cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
        changes => [ clear, change('', 'foo'), tag(0, '', $name) ],
        lines => [ clear, version, change('', 'foo'), tag(1, '', $name) ],
    }, encode_utf8(qq{Should have line and change for "$tag"});
}
is sorted, 14, 'Should have sorted changes 12 times';

# Try a plan with reserved tag name @HEAD.
$file = file qw(t plans reserved-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with reserved tag "@HEAD"';
is sorted, 1, 'Should have sorted changes once';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': "HEAD" is a reserved name',
]], 'And the reserved tag error should have been output';

# Try a plan with reserved tag name @ROOT.
my $root = '@ROOT';
$file = file qw(t plans root.plan);
$fh = IO::File->new(\$root, '<:utf8');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with reserved tag "@ROOT"';
is sorted, 0, 'Should have sorted changes nonce';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    1,
    ': "ROOT" is a reserved name',
]], 'And the reserved tag error should have been output';

# Try a plan with a change name that looks like a sha1 hash.
my $sha1 = '6c2f28d125aff1deea615f8de774599acf39a7a1';
$file = file qw(t plans sha1.plan);
$fh = IO::File->new(\$sha1, '<:utf8');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with SHA1 change name';
is sorted, 0, 'Should have sorted changes nonce';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    1,
    qq{: "$sha1" is invalid because it could be confused with a SHA1 ID},
]], 'And the SHA1 name error should have been output';

# Try a plan with a tag but no change.
$file = file qw(t plans tag-no-change.plan);
$fh = IO::File->new(\"\@foo\nbar", '<:utf8');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with tag but no preceding change';
is sorted, 0, 'Should have sorted changes nonce';
cmp_deeply +MockOutput->get_fail, [[
    "Error in $file at line ",
    1,
    ': Tag "foo" declared without a preceding change',
]], 'And the missing change error should have been output';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe tag';
is sorted, 2, 'Should have sorted changes twice';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    10,
    ': Tag "bar" duplicates earlier declaration on line 5',
]], 'And the dupe tag error should have been output';

# Try a plan with a duplicate change within a tag section.
$file = file qw(t plans dupe-change.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe change';
is sorted, 1, 'Should have sorted changes once';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    7,
    ': Change "greets" duplicates earlier declaration on line 5',
]], 'And the dupe change error should have been output';

# Try a plan with pragmas.
$file = file qw(t plans pragmas.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with pragmas"';
is sorted, 1, 'Should have sorted changes once';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    changes => [
        clear,
        change( '', 'hey'),
        change( '', 'you'),
    ],
    lines => [
        clear,
        prag( '', ' ', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION),
        prag( '  ', '', 'foo', ' ', '=', ' ', 'bar', '    ', ' lolz'),
        blank(),
        change( '', 'hey'),
        change( '', 'you'),
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
        change( '', 'hey', '', '', '+' ),
        change( '', 'you', '', '', '+' ),
        change( ' ', 'dr_evil', '', '', '+  ' ),
        tag(0, '', 'foo' ),
        change(  '', 'this/rocks', '  ', '', '+'),
        change( ' ', 'hey-there' ),
        change( '', 'dr_evil', ' ', ' revert!', '-'),
        tag(0, ' ', 'bar', ' ' ),
    ],
    lines => [
        clear,
        version,
        change( '', 'hey', '', '', '+' ),
        change( '', 'you', '', '', '+' ),
        change( ' ', 'dr_evil', '', '', '+  ' ),
        tag(1, '', 'foo' ),
        blank( '   '),
        change(  '', 'this/rocks', '  ', '', '+'),
        change( ' ', 'hey-there' ),
        change( '', 'dr_evil', ' ', ' revert!', '-'),
        tag(1, ' ', 'bar', ' ' ),
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
    change( '', 'roles', '', '', '+' ),
    change( '', 'users', '', '', '+', '    ', ['roles'] ),
    change( '', 'add_user', '', '', '+', ' ', [qw( users roles)] ),
    change( '', 'dr_evil', '', '', '+' ),
    tag(0, '', 'alpha'),
    change( '', 'users', '', '', '+', ' ', ['users@alpha'] ),
    change( '', 'dr_evil', '', '', '-' ),
    change( '', 'del_user', '', '', '+', ' ' , ['users'], ['dr_evil'] ),
], 'The changes should include the dependencies';
is sorted, 2, 'Should have sorted changes twice';

# Should fail with dependencies on tags.
$file = file qw(t plans tag_dependencies.plan);
$fh = IO::File->new(\"foo\n\@bar :foo", '<:utf8');
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan with tag dependencies';
throws_ok { $plan->_parse($file, $fh) }  qr/^FAIL:/,
    'Should get an exception for tag with dependencies';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    2,
    ': Tags may not specify dependencies',
]], 'And the message should say that tags do not support dependencies';

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
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(1,   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(1,   '', 'bar', ' '),
        tag(1,   '', 'baz', ''),
], 'Lines should be parsed from file';
cmp_deeply [$plan->changes], [
        clear,
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(0,   '', 'foo', ' ', ' look, a tag!'),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(0,   '', 'bar', ' '),
        tag(0,   '', 'baz', ''),
], 'Changes should be parsed from file';
clear, change('', 'you');
my $foo_tag = (tag(1,   '', 'foo', ' ', ' look, a tag!'));
change(   '', 'hey-there', ' ', ' trailing comment!');
cmp_deeply [$plan->tags], [
    $foo_tag,
    tag(1,   '', 'bar', ' '),
    tag(1,   '', 'baz', ''),
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
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(1,   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(1,   '', 'bar', ' '),
        tag(1,   '', 'baz', ''),
    ],
    changes => [
        clear,
        change(  '', 'hey'),
        change(  '', 'you'),
        tag(0,   '', 'foo', ' ', ' look, a tag!'),
        change(  '', 'this/rocks', '  '),
        change(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(0,   '', 'bar', ' '),
        tag(0,   '', 'baz', ''),
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
throws_ok { $plan->seek('nonesuch') } qr/FAIL:/,
    'Should die seeking invalid change';
cmp_deeply +MockOutput->get_fail, [['Cannot find change "nonesuch" in plan']],
    'And the failure should be sent to output';

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
    throws_ok { $plan->_is_valid( tag => $name) } qr/^FAIL:/,
        qq{Should find "$name" invalid};
    cmp_deeply +MockOutput->get_fail, [[
        qq{"$name" is invalid: tags must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ]], qq{And "$name" should trigger the validation error};
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
    . "\@w00t\n",
    'The contents should include the "w00t" tag';

# Try passing the tag name with a leading @.
ok $tag = $plan->add_tag('@alpha'), 'Add tag "@alpha"';
is $plan->index_of('@alpha'), 3, 'Should find "@alpha at index 3';
is $tag->name, 'alpha', 'The returned tag should be @alpha';
is $tag->change, $plan->last, 'The @alpha change should be the last change';

# Should choke on a duplicate tag.
throws_ok { $plan->add_tag('w00t') } qr/^FAIL\b/,
    'Should get error trying to add duplicate tag';
cmp_deeply +MockOutput->get_fail, [[
    'Tag "@w00t" already exists'
]], 'And the error message should report it as a dupe';

# Should choke on an invalid tag names.
for my $name (@bad_names, 'foo#bar') {
    throws_ok { $plan->add_tag($name) } qr/^FAIL:/,
        qq{Should get error for invalid tag "$name"};
    cmp_deeply +MockOutput->get_fail, [[
        qq{"$name" is invalid: tags must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ]], qq{And "$name" should trigger the appropriate error};
}

throws_ok { $plan->add_tag('HEAD') } qr/^FAIL:/,
    'Should get error for reserved tag "HEAD"';
cmp_deeply +MockOutput->get_fail, [[
    '"HEAD" is a reserved name'
]], 'And the reserved name error should be output';

throws_ok { $plan->add_tag('ROOT') } qr/^FAIL:/,
    'Should get error for reserved tag "ROOT"';
cmp_deeply +MockOutput->get_fail, [[
    '"ROOT" is a reserved name'
]], 'And the reserved name error should be output';

throws_ok { $plan->add_tag($sha1) } qr/^FAIL:/,
    'Should get error for a SHA1 tag';
cmp_deeply +MockOutput->get_fail, [[
    qq{"$sha1" is invalid because it could be confused with a SHA1 ID},
]], 'And the reserved name error should be output';

##############################################################################
# Try adding a change.
ok my $new_change = $plan->add('booyah'), 'Add change "booyah"';
is $plan->count, 5, 'Should have 5 changes';
is $plan->index_of('booyah'), 4, 'Should find "booyah at index 4';
is $plan->last->name, 'booyah', 'Last change should be "booyah"';
isa_ok $new_change, 'App::Sqitch::Plan::Change';
is $new_change->as_string, 'booyah',
    'Should have plain stringification of "booya"';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)')
    . "\@w00t\n\@alpha\nbooyah\n",
    'The contents should include the "booyah" change';

# Make sure dependencies are verified.
ok $new_change = $plan->add('blow', ['booyah']), 'Add change "blow"';
is $plan->count, 6, 'Should have 6 changes';
is $plan->index_of('blow'), 5, 'Should find "blow at index 5';
is $plan->last->name, 'blow', 'Last change should be "blow"';
is $new_change->as_string, 'blow :booyah',
    'Should have nice stringification of "blow :booyah"';
is [$plan->lines]->[-1], $new_change,
    'The new change should have been appended to the lines, too';

# Should choke on a duplicate change.
throws_ok { $plan->add('blow') } qr/^FAIL\b/,
    'Should get error trying to add duplicate change';
cmp_deeply +MockOutput->get_fail, [[
    qq{Change "blow" already exists.\n},
    'Use "sqitch rework" to copy and rework it'
]], 'And the error message should suggest "rework"';

# Should choke on an invalid change names.
for my $name (@bad_names) {
    throws_ok { $plan->add($name) } qr/FAIL:/,
        qq{Should get error for invalid change "$name"};
    cmp_deeply +MockOutput->get_fail, [[
        qq{"$name" is invalid: changes must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ]], qq{And "$name" should trigger the appropriate error};
}

# Try a reserved name.
throws_ok { $plan->add('HEAD') } qr/^FAIL:/,
    'Should get error for reserved tag "HEAD"';
cmp_deeply +MockOutput->get_fail, [[
    '"HEAD" is a reserved name'
]], 'And the reserved name error should be output';

throws_ok { $plan->add('ROOT') } qr/^FAIL:/,
    'Should get error for reserved tag "ROOT"';
cmp_deeply +MockOutput->get_fail, [[
    '"ROOT" is a reserved name'
]], 'And the reserved name error should be output';

# Try an invalid dependency.
throws_ok { $plan->add('whu', ['nonesuch' ] ) } qr/^FAIL\b/,
    'Should get failure for failed dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Cannot add change "whu": ',
    'requires unknown change "nonesuch"'
]], 'The dependency error should have been emitted';

# Should choke on an unknown tag, too.
throws_ok { $plan->add('whu', ['@nonesuch' ] ) } qr/^FAIL\b/,
    'Should get failure for failed tag dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Cannot add change "whu": ',
    'requires unknown change "@nonesuch"'
]], 'The tag dependency error should have been emitted';

# Should choke on a change that looks like a SHA1.
throws_ok { $plan->add($sha1) } qr/^FAIL:/,
    'Should get error for a SHA1 change';
cmp_deeply +MockOutput->get_fail, [[
    qq{"$sha1" is invalid because it could be confused with a SHA1 ID},
]], 'And the reserved name error should be output';

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
is $rev_change->as_string, 'you :you@bar',
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
is $rev_change2->as_string, 'you :you@beta1',
    'It should require the previous "you" change';
is [$plan->lines]->[-1], $rev_change2,
    'The new reworking should have been appended to the lines';

# Make sure it was appended to the plan.
is $plan->index_of('you@HEAD'), 7, 'It should be at position 7';
is $plan->count, 8, 'The plan count should be 8';

# Try a nonexistent change name.
throws_ok { $plan->rework('nonexistent') } qr/^FAIL:/,
    'rework should die on nonexistent change';
cmp_deeply +MockOutput->get_fail, [[
    qq{Change "nonexistent" does not exist.\n},
    qq{Use "sqitch add nonexistent" to add it to the plan},
]], 'And the error should suggest "sqitch add"';

# Try reworking without an intervening tag.
throws_ok { $plan->rework('you') } qr/^FAIL:/,
    'rework_stpe should die on lack of intervening tag';
cmp_deeply +MockOutput->get_fail, [[
    qq{Cannot rework "you" without an intervening tag.\n},
    'Use "sqitch tag" to create a tag and try again'
]], 'And the error should suggest "sqitch tag"';

# Make sure it checks dependencies.
throws_ok { $plan->rework('booyah', ['nonesuch' ] ) } qr/^FAIL\b/,
    'rework should die on failed dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Cannot rework change "booyah": ',
    'requires unknown change "nonesuch"'
]], 'The dependency error should have been emitted';

##############################################################################
# Try a plan with a duplicate change in different tag sections.
$file = file qw(t plans dupe-change-diff-tag.plan);
$sqitch = App::Sqitch->new(plan_file => $file, uri => $uri);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan shoud work plan with dupe change across tags';
cmp_deeply [ $plan->lines ], [
    clear,
    version,
    change(  '', 'whatever'),
    tag(1,   '', 'foo'),
    blank(),
    change(  '', 'hi'),
    tag(1,   '', 'bar'),
    blank(),
    change(  '', 'greets'),
    change(  '', 'whatever'),
], 'Lines with dupe change should be read from file';

cmp_deeply [ $plan->changes ], [
    clear,
    change(  '', 'whatever'),
    tag(0,   '', 'foo'),
    change(  '', 'hi'),
    tag(0,   '', 'bar'),
    change(  '', 'greets'),
    change(  '', 'whatever'),
], 'Noes with dupe change should be read from file';
is sorted, 3, 'Should have sorted changes three times';

# Try to find whatever.
throws_ok { $plan->index_of('whatever') } qr/^Key "whatever" at multiple indexes/,
    'Should get an error trying to find dupe key.';
is $plan->index_of('whatever@HEAD'), 3, 'Should get 3 for whatever@HEAD';
is $plan->index_of('whatever@bar'), 0, 'Should get 0 for whatever@bar';

# Make sure seek works, too.
throws_ok { $plan->seek('whatever') } qr/^Key "whatever" at multiple indexes/,
    'Should get an error seeking dupe key.';
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
        change '', $_;
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

# Add a cycle.
@deps = ({%ddep, requires => ['that']}, {%ddep, requires => ['this']}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } qr/FAIL:/,
    'Should get failure for a cycle';
cmp_deeply +MockOutput->get_fail, [[
    'Dependency cycle detected beween changes "',
    'this',
    ' and "that"',
]], 'The cylce should have been logged';

# Add an extended cycle.
@deps = (
    {%ddep, requires => ['that']},
    {%ddep, requires => ['other']},
    {%ddep, requires => ['this']}
);
throws_ok { $plan->sort_changes(changes qw(this that other)) } qr/FAIL:/,
    'Should get failure for a two-hop cycle';
cmp_deeply +MockOutput->get_fail, [[
    'Dependency cycle detected beween changes "',
    'this, that',
    ' and "other"',
]], 'The cylce should have been logged';

# Okay, now deal with depedencies from ealier change sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_changes({ foo => 1}, changes qw(this that other))],
    [changes qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep, requires => ['sqitch']}, {%ddep});
cmp_deeply [$plan->sort_changes({sqitch => 1 }, changes qw(this that other))],
    [changes qw(other that this)], 'Should get other, that, this with earlier dependncy';

# Okay, now deal with depedencies from ealier change sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } qr/FAIL:/,
    'Should die on unknown dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Unknown change "foo" required by change "this"',
]], 'And we should emit an error pointing to the offending script';

# Okay, now deal with depedencies from ealier change sections.
@deps = ({%ddep, requires => ['@foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_changes(changes qw(this that other)) } qr/FAIL:/,
    'Should die on unknown dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Unknown change "@foo" required by change "this"',
]], 'And we should emit an error pointing to the offending script';

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
    throws_ok { $plan->_check_dependencies($change, 'bark') } qr/^FAIL\b/,
        qq{Should get error trying to depend on "$req"};
    cmp_deeply +MockOutput->get_fail, [[
        qq{Cannot bark change "lazy": },
        qq{requires unknown change "$req"},
    ]], qq{And should get unknown dependency error for "$req"};
}

done_testing;
