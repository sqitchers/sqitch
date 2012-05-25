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
    App::Sqitch::Plan::Step->new(
        plan    => $plan,
        lspace  => $_[0] // '',
        name    => $_[1],
        rspace  => $_[2] // '',
        comment => $_[3] // '',
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

my $mocker = Test::MockModule->new($CLASS);
# Do no sorting for now.
$mocker->mock(sort_steps => sub { shift, shift; @_ });

##############################################################################
# Test parsing.
my $file = file qw(t plans widgets.plan);
my $fh = $file->open('<:encoding(UTF-8)');
ok my $parsed = $plan->_parse($file, $fh),
    'Should parse simple "widgets.plan"';
isa_ok $parsed->{nodes}, 'Array::AsHash', 'nodes';
isa_ok $parsed->{lines}, 'Array::AsHash', 'lines';

is_deeply [$parsed->{nodes}->values], [
    step(  '', 'hey'),
    step(  '', 'you'),
    tag(   '', 'foo', ' ', ' look, a tag!'),
], 'All "widgets.plan" nodes should be parsed';

is_deeply [$parsed->{lines}->values], [
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
is_deeply { map { $_ => scalar $parsed->{$_}->values } keys %{ $parsed } }, {
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
is_deeply { map { $_ => scalar $parsed->{$_}->values } keys %{ $parsed } }, {

    lines => [
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
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': Invalid step "what what what"; steps must not begin or ',
    'end in punctuation or digits following punctuation'
]], 'And the error should have been output';

# Try other invalid step and tag name issues.
for my $name (
    '^foo',     # No leading punctuation
    'foo bar',  # no white space
    'foo+',     # No trailing punctuation
    'foo+6',    # No trailing punctuation+digit
    'foo+666',  # No trailing punctuation+digits
    '%hi',      # No leading punctuation
    'hi!',      # No trailing punctuation
) {
    for my $line ($name, "\@$name") {
        my $what = $line =~ /^[@]/ ? 'tag' : 'step';
        my $fh = IO::File->new(\$line, '<:utf8');
        throws_ok { $plan->_parse('baditem', $fh) } qr/FAIL:/,
            qq{Should die on plan with bad name "$line"};
        is_deeply +MockOutput->get_fail, [[
            "Syntax error in baditem at line ",
            1,
            qq{: Invalid $what "$line"; ${what}s must not begin or },
            'end in punctuation or digits following punctuation'
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
        is_deeply { map { $_ => scalar $parsed->{$_}->values } keys %{ $parsed } }, {
            nodes => [ $make->('', $name) ],
            lines => [ $make->('', $name) ],
        }, encode_utf8(qq{Should have line and node for "$line"});
    }
}

# Try a plan with a reserved tag name.
$file = file qw(t plans reserved-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with reserved tag';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    5,
    ': "HEAD" is a reserved name',
]], 'And the reserved tag error should have been output';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe tag';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    10,
    ': Tag "bar" duplicates earlier declaration on line ',
    4,
]], 'And the dupe tag error should have been output';

# Try a plan with a duplicate step within a tag section.
$file = file qw(t plans dupe-step.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe step';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    7,
    ': Step "greets" duplicates earlier declaration on line ',
    5,
]], 'And the dupe step error should have been output';

# Try a plan with a duplicate step in different tag sections.
$file = file qw(t plans dupe-step-diff-tag.plan);
$fh = $file->open('<:encoding(UTF-8)');
throws_ok { $plan->_parse($file, $fh) } qr/FAIL:/,
    'Should die on plan with dupe step across tags';
is_deeply +MockOutput->get_fail, [[
    "Syntax error in $file at line ",
    8,
    ': Step "whatever" duplicates earlier declaration on line ',
    1,
]], 'And the second dupe step error should have been output';

# Make sure that all() loads the plan.
$file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new(plan_file => $file);
isa_ok $plan = App::Sqitch::Plan->new(sqitch => $sqitch), $CLASS,
    'Plan with sqitch with plan file';
is_deeply [$plan->lines], [
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        step(  '', 'this/rocks', '  '),
        tag(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
], 'Lines should be parsed from file';
is_deeply [$plan->nodes], [
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        step(  '', 'this/rocks', '  '),
        tag(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
], 'Nodes should be parsed from file';

ok $parsed = $plan->load, 'Load should parse plan from file';
is_deeply { map { $_ => scalar $parsed->{$_}->values } keys %{ $parsed } }, {
    lines => [
        blank('', ' This is a comment'),
        blank(),
        blank('', ' And there was a blank line.'),
        blank(),
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        blank('   '),
        step(  '', 'this/rocks', '  '),
        tag(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
    nodes => [
        step(  '', 'hey'),
        step(  '', 'you'),
        tag(   '', 'foo', ' ', ' look, a tag!'),
        step(  '', 'this/rocks', '  '),
        tag(   '', 'hey-there', ' ', ' trailing comment!'),
        tag(   '', 'bar', ' '),
        tag(   '', 'baz', ''),
    ],
}, 'And the parsed file should have lines and nodes';

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
is $plan->index_of($node->name), 0, "Index of $node should be 0";
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
is_deeply +MockOutput->get_fail, [['Cannot find node "nonesuch" in plan']],
    'And the failure should be sent to output';

# Get all!
my @nodes = ($node, $next, $third, $fourth, $fifth, $sixth, $seventh);
is_deeply [$plan->nodes], \@nodes, 'All should return all nodes';
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
    . $file->slurp(iomode => '<:encoding(UTF-8)'),
    'The contents should look right';

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
is_deeply $plan->sort_steps({}, steps qw(this that other)),
    [steps qw(this that other)], 'Should get original order when no dependencies';

@deps = ({%ddep}, {%ddep}, {%ddep});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(this that other)], 'Should get original order when no prepreqs';

# Have that require this.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(this that other)], 'Should get original order when that requires this';

# Have other require that.
@deps = ({%ddep}, {%ddep, requires => ['this']}, {%ddep, requires => ['that']});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(this that other)], 'Should get original order when other requires that';

# Have this require other.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(other this that)], 'Should get other first when this requires it';

# Have other other require taht.
@deps = ({%ddep, requires => ['other']}, {%ddep}, {%ddep, requires => ['that']});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(that other this)], 'Should get that, other, this now';

# Have this require other and that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(other that this)], 'Should get other, that, this now';

# Have this require other and that, and other requore that.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep}, {%ddep, requires => ['that']});
is_deeply $plan->sort_steps(steps qw(this that other)),
    [steps qw(that other this)], 'Should get that, other, this again';

# Add a cycle.
@deps = ({%ddep, requires => ['that']}, {%ddep, requires => ['this']}, {%ddep});
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should get failure for a cycle';
is_deeply +MockOutput->get_fail, [[
    'Dependency cycle detected beween steps "',
    'this',
    ' and "that"',
]], 'The cylce should have been logged';

# Okay, now deal with depedencies from ealier node sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
is_deeply $plan->sort_steps({ foo => 1}, steps qw(this that other)),
    [steps qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ({%ddep, requires => ['other', 'that']}, {%ddep, requires => ['sqitch']}, {%ddep});
is_deeply $plan->sort_steps({sqitch => 1 }, steps qw(this that other)),
    [steps qw(other that this)], 'Should get other, that, this with earlier dependncy';

# Have a failed dependency.
# Okay, now deal with depedencies from ealier node sections.
@deps = ({%ddep, requires => ['foo']}, {%ddep}, {%ddep});
throws_ok { $plan->sort_steps(steps qw(this that other)) } qr/FAIL:/,
    'Should die on unknown dependency';
is_deeply +MockOutput->get_fail, [[
    'Unknown step "foo" required in ', 'sql/deploy/this.sql'
]], 'And we should emit an error pointing to the offending script';

done_testing;
