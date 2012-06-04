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
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    sqitch
    nodes
    position
    load
    _parse
    sort_steps
    open_script
);

my $sqitch = App::Sqitch->new;
isa_ok my $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS;

# Set up some some utility functions for creating nodes.
sub blank {
    App::Sqitch::Plan::Blank->new(
        plan    => $plan,
        lspace  => $_[0] // '',
        comment => $_[1] // '',
    );
}

sub step {
    my @op = defined $_[4] ? split /([+-])/, $_[4] : ();
    App::Sqitch::Plan::Step->new(
        plan     => $plan,
        lspace   => $_[0] // '',
        name     => $_[1],
        rspace   => $_[2] // '',
        comment  => $_[3] // '',
        lopspace => $op[0] // '',
        operator => $op[1] // '',
        ropspace => $op[2] // '',
    );
}

sub tag {
    App::Sqitch::Plan::Tag->new(
        plan    => $plan,
        lspace  => $_[0] // '',
        name    => $_[1],
        rspace  => $_[2] // '',
        comment => $_[3] // '',
    );
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
$mocker->mock(sort_steps => sub { $sorted++; shift, shift; @_ });

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
is sorted, 1, 'Should have sorted steps';
isa_ok $parsed->{nodes}, 'App::Sqitch::Plan::NodeList', 'nodes';
isa_ok $parsed->{lines}, 'App::Sqitch::Plan::LineList', 'lines';

cmp_deeply [$parsed->{nodes}->items], [
    step(  '', 'hey'),
    step(  '', 'you'),
    tag(   '', 'foo', ' ', ' look, a tag!'),
], 'All "widgets.plan" nodes should be parsed';

cmp_deeply [$parsed->{lines}->items], [
    version,
    blank('', ' This is a comment'),
    blank(),
    blank(' ', ' And there was a blank line.'),
    blank(),
    step(  '', 'hey'),
    step(  '', 'you'),
    tag(   '', 'foo', ' ', ' look, a tag!'),
], 'All "widgets.plan" lines should be parsed';

# Plan with multiple tags.
$file = file qw(t plans multi.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse multi-tagged "multi.plan"';
is sorted, 2, 'Should have sorted steps twice';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    nodes => [
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
    lines => [
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
}, 'Should have "multi.plan" lines and nodes';

# Try a plan with steps appearing without a tag.
$file = file qw(t plans steps-only.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh), 'Should read plan with no tags';
is sorted, 1, 'Should have sorted steps';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {

    lines => [
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        step(  '', 'whatwhatwhat'),
    ],
    nodes => [
        step(  '', 'hey'),
        step(  '', 'you'),
        step(  '', 'whatwhatwhat'),
    ],
}, 'Should have lines and nodes for tagless plan';

# Try a plan with a bad step name.
$file = file qw(t plans bad-step.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with bad step name';
is sorted, 0, 'Should not have sorted steps';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': Invalid step "what what what"; steps must not begin with ',
    'punctuation or end in punctuation or digits following punctuation'
]], 'And the error should have been output';

my @bad_names = (
    '^foo',     # No leading punctuation
    'foo bar',  # no white space
    'foo+',     # No trailing punctuation
    'foo+6',    # No trailing punctuation+digit
    'foo+666',  # No trailing punctuation+digits
    '%hi',      # No leading punctuation
    'hi!',      # No trailing punctuation
    'foo@bar'   # No @ allowed at all.
);

# Try other invalid step and tag name issues.
for my $name (@bad_names) {
    for my $line ($name, "\@$name") {
        next if $line eq '%hi'; # This would be a pragma.
        my $what = $line =~ /^[@]/ ? 'tag' : 'step';
        my $fh = IO::File->new(\$line, '<:utf8');
        throws_ok { $plan->_parse('baditem', $fh) } qr/FAIL:/,
            qq{Should die on plan with bad name "$line"};
        is sorted, 0, 'Should not have sorted steps';
        cmp_deeply +MockOutput->get_fail, [[
            "Syntax error in baditem at line ",
            1,
            qq{: Invalid $what "$line"; ${what}s must not begin with },
            'punctuation or end in punctuation or digits following punctuation'
        ]], qq{And "$line" should trigger the appropriate error};
    }
}

# Try some valid step and tag names.
for my $name (
    'foo',     # alpha
    '12',      # digits
    't',       # char
    '6',       # digit
    '阱阪阬',   # multibyte
    'foo/bar', # middle punct
) {
    for my $line ($name, "\@$name") {
        my $fh = IO::File->new(\$line, '<:utf8');
        my $make = $line =~ /^[@]/ ? \&tag : \&step;
        ok my $parsed = $plan->_parse('gooditem', $fh),
            encode_utf8(qq{Should parse "$line"});
        cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
            nodes => [ $make->('', $name) ],
            lines => [ version, $make->('', $name) ],
        }, encode_utf8(qq{Should have line and node for "$line"});
    }
}
is sorted, 6, 'Should have sorted steps six times';

# Try a plan with a reserved tag name.
$file = file qw(t plans reserved-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with reserved tag';
is sorted, 1, 'Should have sorted steps once';
cmp_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': "HEAD" is a reserved name',
]], 'And the reserved tag error should have been output';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe tag';
is sorted, 2, 'Should have sorted steps twice';
cmp_deeply +MockOutput->get_fail, [[
    "Error in $file at line ",
    10,
    ': Tag "bar" duplicates earlier declaration on line 4',
]], 'And the dupe tag error should have been output';

# Try a plan with a duplicate step within a tag section.
$file = file qw(t plans dupe-step.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe step';
is sorted, 1, 'Should have sorted steps once';
cmp_deeply +MockOutput->get_fail, [[
    "Error in $file at line ",
    7,
    ': Step "greets" duplicates earlier declaration on line 5',
]], 'And the dupe step error should have been output';

# Try a plan with pragmas.
$file = file qw(t plans pragmas.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with pragmas"';
is sorted, 1, 'Should have sorted steps once';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    nodes => [
        step( '', 'hey'),
        step( '', 'you'),
    ],
    lines => [
        prag( '', ' ', 'syntax-version', '', '=', '', App::Sqitch::Plan::SYNTAX_VERSION),
        prag( '  ', '', 'foo', ' ', '=', ' ', 'bar', '    ', ' lolz'),
        blank(),
        step( '', 'hey'),
        step( '', 'you'),
        blank(),
        prag( '', ' ', 'strict'),
    ],
}, 'Should have "multi.plan" lines and nodes';

# Try a plan with deploy/revert operators.
$file = file qw(t plans deploy-and-revert.plan);
$fh = $file->open('<:encoding(UTF-8)');
ok $parsed = $plan->_parse($file, $fh),
    'Should parse plan with deploy and revert operators';
is sorted, 2, 'Should have sorted steps twice';

cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    nodes => [
        step( '', 'hey', '', '', '+' ),
        step( '', 'you', '', '', '+' ),
        step( ' ', 'dr_evil', '', '', '+  ' ),
        tag( '', 'foo' ),
        step(  '', 'this/rocks', '  ', '', '+'),
        step( ' ', 'hey-there' ),
        step( '', 'dr_evil', ' ', ' revert!', '-'),
        tag( ' ', 'bar', ' ' ),
    ],
    lines => [
        version,
        step( '', 'hey', '', '', '+' ),
        step( '', 'you', '', '', '+' ),
        step( ' ', 'dr_evil', '', '', '+  ' ),
        tag( '', 'foo' ),
        blank( '   '),
        step(  '', 'this/rocks', '  ', '', '+'),
        step( ' ', 'hey-there' ),
        step( '', 'dr_evil', ' ', ' revert!', '-'),
        tag( ' ', 'bar', ' ' ),
    ],
}, 'Should have "deploy-and-revert.plan" lines and nodes';

# Make sure that lines() loads the plan.
$file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan file';
cmp_deeply [$plan->lines], [
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
], 'Lines should be parsed from file';
cmp_deeply [$plan->nodes], [
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
], 'Nodes should be parsed from file';
is sorted, 2, 'Should have sorted steps twice';

ok $parsed = $plan->load, 'Load should parse plan from file';
cmp_deeply { map { $_ => [$parsed->{$_}->items] } keys %{ $parsed } }, {
    lines => [
        version,
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
    nodes => [
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        step(  '', 'this/rocks', '  '),
        step(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
}, 'And the parsed file should have lines and nodes';
is sorted, 2, 'Should have sorted steps twice';


##############################################################################
# Test the interator interface.
can_ok $plan, qw(
    index_of
    seek
    reset
    next
    current
    peek
    do
);

is $plan->position, -1, 'Position should start at -1';
is $plan->current, undef, 'Current should be undef';
ok my $node = $plan->next, 'Get next node';
isa_ok $node, 'App::Sqitch::Plan::Step', 'First node';
is $node->name, 'hey', 'It should be the first step';
is $plan->position, 0, 'Position should be at 0';
is $plan->count, 7, 'Count should be 7';
is $plan->current, $node, 'Current should be current';

ok my $next = $plan->peek, 'Peek to next node';
isa_ok $next, 'App::Sqitch::Plan::Step', 'Peeked node';
is $next->name, 'you', 'Peeked node should be second step';
is $plan->last->format_name, '@baz', 'last() should return last node';
is $plan->current, $node, 'Current should still be current';
is $plan->peek, $next, 'Peek should still be next';
is $plan->next, $next, 'Next should be the second node';
is $plan->position, 1, 'Position should be at 1';

ok my $third = $plan->peek, 'Peek should return an object';
isa_ok $third, 'App::Sqitch::Plan::Tag', 'Third node';
is $third->name, 'foo', 'It should be the foo tag';
is $plan->current, $next, 'Current should be the second node';
is $plan->next, $third, 'Should get third node next';
is $plan->position, 2, 'Position should be at 2';
is $plan->current, $third, 'Current should be third node';

ok my $fourth = $plan->next, 'Get fourth node';
isa_ok $fourth, 'App::Sqitch::Plan::Step', 'Fourth node';
is $fourth->name, 'this/rocks', 'Fourth node should be "this/rocks"';
is $plan->position, 3, 'Position should be at 3';

ok my $fifth = $plan->next, 'Get fifth node';
isa_ok $fifth, 'App::Sqitch::Plan::Step', 'Fifth node';
is $fifth->name, 'hey-there', 'Fifth node should be "hey-there"';
is $plan->position, 4, 'Position should be at 4';

ok my $sixth = $plan->next, 'Get sixth node';
isa_ok $sixth, 'App::Sqitch::Plan::Tag', 'Sixth node';
is $sixth->name, 'bar', 'Sixth node should be "bar"';
is $plan->position, 5, 'Position should be at 5';

ok my $seventh = $plan->next, 'Get sevent node';
isa_ok $seventh, 'App::Sqitch::Plan::Tag', 'Sevent node';
is $seventh->name, 'baz', 'Sevent node should be "baz"';
is $plan->position, 6, 'Position should be at 6';

is $plan->peek, undef, 'Peek should return undef';
is $plan->next, undef, 'Next should return undef';
is $plan->position, 7, 'Position should be at 7';

is $plan->next, undef, 'Next should still return undef';
is $plan->position, 7, 'Position should still be at 7';
ok $plan->reset, 'Reset the plan';

is $plan->position, -1, 'Position should be back at -1';
is $plan->current, undef, 'Current should still be undef';
is $plan->next, $node, 'Next should return the first node again';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $node, 'Current should be first node';
is $plan->index_of($node->name), 0, "Index of node should be 0";
is $plan->index_of('@bar'), 5, 'Index of @bar should be 5';
ok $plan->seek('@bar'), 'Seek to the "@bar" node';
is $plan->position, 5, 'Position should be at 5 again';
is $plan->current, $sixth, 'Current should be sixth again';
is $plan->index_of('you'), 1, 'Index of you should be 1';
ok $plan->seek('you'), 'Seek to the "you" node';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';
is $plan->index_of('baz'), undef, 'Index of baz should be undef';
is $plan->index_of('@baz'), 6, 'Index of @baz should be 6';
ok $plan->seek('@baz'), 'Seek to the "baz" node';
is $plan->position, 6, 'Position should be at 6 again';
is $plan->current, $seventh, 'Current should be seventh again';

# Make sure seek() chokes on a bad node name.
throws_ok { $plan->seek('nonesuch') } qr/FAIL:/,
    'Should die seeking invalid node';
cmp_deeply +MockOutput->get_fail, [['Cannot find node "nonesuch" in plan']],
    'And the failure should be sent to output';

# Get all!
my @nodes = ($node, $next, $third, $fourth, $fifth, $sixth, $seventh);
cmp_deeply [$plan->nodes], \@nodes, 'All should return all nodes';
ok $plan->reset, 'Reset the plan again';
$plan->do(sub {
    is shift, $nodes[0], 'Node ' . $nodes[0]->name . ' should be passed to do sub';
    is $_, $nodes[0], 'Node ' . $nodes[0]->name . ' should be the topic in do sub';
    shift @nodes;
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
    qq{# Generated by Sqitch v$v.\n#\n\n}
    . '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)'),
    'The contents should look right';

##############################################################################
# Try adding a tag.
ok $plan->add_tag('w00t'), 'Add tag "w00t"';
is $plan->count, 8, 'Should have 8 nodes';
is $plan->index_of('@w00t'), 7, 'Should find "@w00t at index 7';
is $plan->last->name, 'w00t', 'Last node should be "w00t"';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    qq{# Generated by Sqitch v$v.\n#\n\n}
    . '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)')
    . "\@w00t\n",
    'The contents should include the "w00t" tag';

# Should choke on a duplicate tag.
throws_ok { $plan->add_tag('w00t') } qr/^FAIL\b/,
    'Should get error trying to add duplicate tag';
cmp_deeply +MockOutput->get_fail, [[
    'Tag "@w00t" already exists'
]], 'And the error message should report it as a dupe';

# Should choke on an invalid tag names.
for my $name (@bad_names) {
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

##############################################################################
# Try adding a step.
ok $plan->add_step('booyah'), 'Add step "booyah"';
is $plan->count, 9, 'Should have 9 nodes';
is $plan->index_of('booyah'), 8, 'Should find "booyah at index 8';
is $plan->last->name, 'booyah', 'Last node should be "booyah"';

ok $plan->write_to($to), 'Write out the file again';
file_contents_is $to,
    qq{# Generated by Sqitch v$v.\n#\n\n}
    . '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION . $/
    . $file->slurp(iomode => '<:encoding(UTF-8)')
    . "\@w00t\nbooyah\n",
    'The contents should include the "booyah" step';

# Make sure dependencies are verified.
ok $plan->add_step('blow', ['booyah']), 'Add step "blow"';
is $plan->count, 10, 'Should have 10 nodes';
is $plan->index_of('blow'), 9, 'Should find "blow at index 9';
is $plan->last->name, 'blow', 'Last node should be "blow"';

# Should choke on a duplicate step.
throws_ok { $plan->add_step('blow') } qr/^FAIL\b/,
    'Should get error trying to add duplicate step';
cmp_deeply +MockOutput->get_fail, [[
    'Step "blow" already exists. Add a tag to modify it.'
]], 'And the error message should report it as a dupe';

# But if we first add a tag, it should work!
ok $plan->add_tag('groovy'), 'Add tag "Groovy"';
ok $plan->add_step('blow'), 'Add step "blow"';
is $plan->count, 12, 'Should have 12 nodes';
is $plan->index_of('blow@HEAD'), 11, 'Should find "blow@HEAD at index 11';
is $plan->last->name, 'blow', 'Last node should be "blow"';

# Should choke on an invalid step names.
for my $name (@bad_names) {
    throws_ok { $plan->add_step($name) } qr/FAIL:/,
        qq{Should get error for invalid step "$name"};
    cmp_deeply +MockOutput->get_fail, [[
        qq{"$name" is invalid: steps must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ]], qq{And "$name" should trigger the appropriate error};
}

# Try a reserved name.
throws_ok { $plan->add_step('HEAD') } qr/^FAIL:/,
    'Should get error for reserved tag "HEAD"';
cmp_deeply +MockOutput->get_fail, [[
    '"HEAD" is a reserved name'
]], 'And the reserved name error should be output';

# Try an invalid depednency.
throws_ok { $plan->add_step('whu', ['nonesuch' ] ) } qr/^FAIL\b/,
    'Should get failure for failed dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Cannot add step "whu": ',
    'requires uknown step "nonesuch"'
]], 'The dependency error should have been emitted';

# Should choke on an unknown tag, too.
throws_ok { $plan->add_step('whu', ['@nonesuch' ] ) } qr/^FAIL\b/,
    'Should get failure for failed tag dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Cannot add step "whu": ',
    'requires uknown tag "@nonesuch"'
]], 'The tag dependency error should have been emitted';

##############################################################################
# Try a plan with a duplicate step in different tag sections.
$file = file qw(t plans dupe-step-diff-tag.plan);
$sqitch = App::Sqitch->new(plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan shoud work plan with dupe step across tags';
cmp_deeply [ $plan->lines ], [
    version,
    step(  '', 'whatever'),
    tag(   '', 'foo'),
    blank(),
    step(  '', 'hi'),
    tag(   '', 'bar'),
    blank(),
    step(  '', 'greets'),
    step(  '', 'whatever'),
], 'Lines with dupe step should be read from file';

cmp_deeply [ $plan->nodes ], [
    step(  '', 'whatever'),
    tag(   '', 'foo'),
    step(  '', 'hi'),
    tag(   '', 'bar'),
    step(  '', 'greets'),
    step(  '', 'whatever'),
], 'Noes with dupe step should be read from file';
is sorted, 3, 'Should have sorted steps three times';

# Try to find whatever.
throws_ok { $plan->index_of('whatever') } qr/^Key "whatever" at multiple indexes/,
    'Should get an error trying to find dupe key.';
is $plan->index_of('whatever@HEAD'), 5, 'Should get 5 for whatever@HEAD';
is $plan->index_of('whatever@bar'), 0, 'Should get 0 for whatever@bar';

# Make sure seek works, too.
throws_ok { $plan->seek('whatever') } qr/^Key "whatever" at multiple indexes/,
    'Should get an error seeking dupe key.';
ok $plan->seek('whatever@HEAD'), 'Seek whatever@HEAD';
is $plan->position, 5, 'Position should be 5';
ok $plan->seek('whatever@bar'), 'Seek whatever@bar';
is $plan->position, 0, 'Position should be 0';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy stuff))->stringify;
END { remove_tree 'sql' };

can_ok $CLASS, 'open_script';
my $step_file = file qw(sql deploy bar.sql);
$fh = $step_file->open('>') or die "Cannot open $step_file: $!\n";
$fh->say('-- This is a comment');
$fh->close;
ok $fh = $plan->open_script($step_file), 'Open bar.sql';
is $fh->getline, "-- This is a comment\n", 'It should be the right file';
$fh->close;

file(qw(sql deploy baz.sql))->touch;
ok $fh = $plan->open_script(file qw(sql deploy baz.sql)), 'Open baz.sql';
is $fh->getline, undef, 'It should be empty';

##############################################################################
# Test sort_steps()
$mocker->unmock('sort_steps');
can_ok $CLASS, 'sort_steps';
my @deps;
my $mock_step = Test::MockModule->new('App::Sqitch::Plan::Step');
$mock_step->mock(_dependencies => sub { shift @deps });

sub steps {
    map {
        step '', $_;
    } @_;
}

# Start with no dependencies.
my %ddep = ( requires => [], conflicts => [] );
@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_steps({}, steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order when no dependencies';

@deps = ({%ddep}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order when no prepreqs';

# Have that require this.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order when that requires this';

# Have other require that.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order when other requires that';

# Have this require other.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(other this that)], 'Should get other first when this requires it';

# Have other other require taht.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(that other this)], 'Should get that, other, this now';

# Have this require other and that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(other that this)], 'Should get other, that, this now';

# Have this require other and that, and other requore that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep, requires => ['that']});
cmp_deeply [$plan->sort_steps(steps qw(this that other))],
    [steps qw(that other this)], 'Should get that, other, this again';

# Have that require a tag.
@deps = ({%ddep}, {%ddep, requires => ['@howdy']}, {%ddep});
cmp_deeply [$plan->sort_steps({'@howdy' => 2 }, steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order when requiring a tag';

# Add a cycle.
@deps = ({%ddep, requires => ['that']}, {%ddep, requires => ['this']}, {%ddep});
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should get failure for a cycle';
cmp_deeply +MockOutput->get_fail, [[
    'Dependency cycle detected beween steps "',
    'this',
    ' and "that"',
]], 'The cylce should have been logged';

# Add an extended cycle.
@deps = (
    {%ddep, requires => ['that']},
    {%ddep, requires => ['other']},
    {%ddep, requires => ['this']}
);
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should get failure for a two-hop cycle';
cmp_deeply +MockOutput->get_fail, [[
    'Dependency cycle detected beween steps "',
    'this, that',
    ' and "other"',
]], 'The cylce should have been logged';

# Okay, now deal with depedencies from ealier node sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
cmp_deeply [$plan->sort_steps({ foo => 1}, steps qw(this that other))],
    [steps qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep, requires => ['sqitch']}, {%ddep});
cmp_deeply [$plan->sort_steps({sqitch => 1 }, steps qw(this that other))],
    [steps qw(other that this)], 'Should get other, that, this with earlier dependncy';

# Okay, now deal with depedencies from ealier node sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should die on unknown dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Unknown step "foo" required in ', file 'sql/deploy/this.sql'
]], 'And we should emit an error pointing to the offending script';

# Okay, now deal with depedencies from ealier node sections.
@deps = ({%ddep, requires => ['@foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should die on unknown dependency';
cmp_deeply +MockOutput->get_fail, [[
    'Unknown tag "@foo" required in ', file 'sql/deploy/this.sql'
]], 'And we should emit an error pointing to the offending script';

done_testing;
