#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 109;

#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Exception;
use Test::File;
use Test::File::Contents;
use Test::NoWarnings;
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
  all
  position
  load
  load_untracked
  _parse
);

my $sqitch = App::Sqitch->new;
isa_ok my $plan = App::Sqitch::Plan->new( sqitch => $sqitch ), $CLASS;

sub tag {
    App::Sqitch::Plan::Tag->new( names => $_[0], steps => $_[1] );
}

my $mocker = Test::MockModule->new($CLASS);

# Do no sorting for now.
$mocker->mock( _parse_dependencies => {} );

##############################################################################
# Test parsing.
my $file = file qw(t plans widgets.plan);
is_deeply $plan->_parse($file), [ tag [qw(foo)] => [qw(hey you)], ],
  'Should parse simple "widgets.plan"';

# Plan with multiple tags.
$file = file qw(t plans multi.plan);
is_deeply $plan->_parse($file),
  [
    tag( [qw(foo)]     => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
  ],
  'Should parse multi-tagged "multi.plan"';

# Try a plan with steps appearing without a tag.
$file = file qw(t plans steps-only.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with steps beore tags';
is_deeply +MockOutput->get_fail,
  [
    [
        "Syntax error in $file at line ",
        5,
        ': Step "hey" not associated with a tag',
    ]
  ],
  'And the error should have been output';

# Try a plan with a bad step name.
$file = file qw(t plans bad-step.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with bad step name';
is_deeply +MockOutput->get_fail,
  [ [ "Syntax error in $file at line ", 5, ': "what what what"', ] ],
  'And the error should have been output';

# Try a plan with a reserved tag name.
$file = file qw(t plans reserved-tag.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with reserved tag';
is_deeply +MockOutput->get_fail,
  [
    [
        "Syntax error in $file at line ", 4, ': "HEAD+" is a reserved tag name',
    ]
  ],
  'And the reserved tag error should have been output';

# Try a plan with a duplicate tag name.
$file = file qw(t plans dupe-tag.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with dupe tag';
is_deeply +MockOutput->get_fail,
  [
    [
        "Syntax error in $file at line ",
        9, ': Tag "bar" duplicates earlier declaration on line 4',
    ]
  ],
  'And the dupe tag error should have been output';

# Try a plan with a duplicate step within a tag section.
$file = file qw(t plans dupe-step.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with dupe step';
is_deeply +MockOutput->get_fail,
  [
    [
        "Syntax error in $file at line ",
        8, ': Step "greets" duplicates earlier declaration on line 6'
    ]
  ],
  'And the dupe step error should have been output';

# Try a plan with a duplicate step in different tag sections.
$file = file qw(t plans dupe-step-diff-tag.plan);
throws_ok { $plan->_parse($file) } qr/FAIL:/,
  'Should die on plan with dupe step across tags';
is_deeply +MockOutput->get_fail,
  [
    [
        "Syntax error in $file at line ",
        9, ': Step "whatever" duplicates earlier declaration on line 2'
    ]
  ],
  'And the second dupe step error should have been output';

# Make sure that all() loads the plan.
$file = file qw(t plans multi.plan);
$sqitch = App::Sqitch->new( plan_file => $file );
isa_ok $plan = App::Sqitch::Plan->new( sqitch => $sqitch ), $CLASS,
  'Plan with sqitch with plan file';
is_deeply [ $plan->all ],
  [
    tag( [qw(foo)]     => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
  ],
  'plan should be parsed from file';
is_deeply $plan->load,
  [
    tag( [qw(foo)]     => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
  ],
  'Load should parse plan from file';

##############################################################################
# Test the interator interface.
can_ok $plan, qw(
  seek
  reset
  next
  current
  peek
  do
);

is $plan->position, -1,    'Position should start at -1';
is $plan->current,  undef, 'Current should be undef';
ok my $tag = $plan->next, 'Get next tag';
is $tag->names->[0], 'foo', 'Tag should be the first tag';
is $plan->position, 0, 'Position should be at 0';
is $plan->current, $tag, 'Current should be current';
ok my $next = $plan->peek, 'Peek to next tag';
is $next->names->[0], 'bar', 'Peeked tag should be second tag';
is $plan->current, $tag,  'Current should still be current';
is $plan->peek,    $next, 'Peek should still be next';
is $plan->next,    $next, 'Next should be the second tag';
is $plan->position, 1,     'Position should be at 1';
is $plan->peek,     undef, 'Peek should return undef';
is $plan->current, $next, 'Current should be the second tag';
is $plan->next,     undef, 'Next should return undef';
is $plan->position, 2,     'Position should be at 2';
is $plan->current,  undef, 'Current should be undef';
is $plan->next,     undef, 'Next should still be undef';
is $plan->position, 2,     'Position should still be at 2';
ok $plan->reset,    'Reset the plan';
is $plan->position, -1,    'Position should be back at -1';
is $plan->current,  undef, 'Current should still be undef';
is $plan->next, $tag, 'Next should return the first tag again';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $tag, 'Current should be first tag';
ok $plan->seek('bar'), 'Seek to the "bar" tag';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';
ok $plan->seek('foo'), 'Seek to the "foo" tag';
is $plan->position, 0, 'Position should be at 0 again';
is $plan->current, $tag, 'Current should be first again';
ok $plan->seek('baz'), 'Seek to the "baz" tag';
is $plan->position, 1, 'Position should be at 1 again';
is $plan->current, $next, 'Current should be second again';

# Make sure seek() chokes on a bad tag name.
throws_ok { $plan->seek('nonesuch') } qr/FAIL:/,
  'Should die seeking invalid tag';
is_deeply +MockOutput->get_fail, [ ['Cannot find tag "nonesuch" in plan'] ],
  'And the failure should be sent to output';

# Get all!
is_deeply [ $plan->all ], [ $tag, $next ], 'All should return all tags';
my @e = ( $tag, $next );
ok $plan->reset, 'Reset the plan again';
$plan->do(
    sub {
        is shift, $e[0],
          'Tag ' . $e[0]->names->[0] . ' should be passed to do sub';
        is $_, $e[0],
          'Tag ' . $e[0]->names->[0] . ' should be the topic in do sub';
        shift @e;
    }
);

# There should be no more to iterate over.
$plan->do( sub { fail 'Should not get anything passed to do()' } );

##############################################################################
# Test writing the plan.
can_ok $plan, 'write_to';
my $to = file 'plan.out';
END { unlink $to }
file_not_exists_ok $to;
ok $plan->write_to($to), 'Write out the file';
file_exists_ok $to;
my $v = App::Sqitch->VERSION;
file_contents_is $to, <<"EOF", 'The contents should look right';
# Generated by Sqitch v$v.
#

[foo]
hey
you

[bar baz]
this/rocks
hey-there

EOF

##############################################################################
# Test load_untracked.
can_ok $CLASS, 'load_untracked';
make_path dir(qw(sql deploy stuff))->stringify;
END { remove_tree 'sql' }

my @tags = ( tag ['foo'] => [qw(bar baz)] );

is $plan->load_untracked( \@tags ), undef, 'load_untracked should return undef';

# Make sure we have the bar and baz steps.
file(qw(sql deploy bar.sql))->touch;
file(qw(sql deploy baz.sql))->touch;

is $plan->load_untracked( \@tags ), undef,
  'load_untracked should still return undef';

# Now add an unknown step.
file(qw(sql deploy yo.sql))->touch;
ok $tag = $plan->load_untracked( \@tags ),
  'load_untracked now should return a tag';
is $tag->dump, tag( ['HEAD+'] => [qw(yo)] )->dump,
  'The tag should have the expected name and step';

# Put Try adding one to a subdirectory.
file(qw(sql deploy stuff wow.sql))->touch;
ok $tag = $plan->load_untracked( \@tags ),
  'load_untracked now should again return a tag';
my $exp = tag ['HEAD+'] => [qw(yo stuff/wow)];
is $tag->dump, $exp->dump, 'The tag should have the subdirectory step';

# Make sure VCS directories are ignored.
for my $subdir (qw(CVS .git .svn)) {
    my $dir = dir qw(sql deploy), $subdir;
    make_path $dir->stringify;
    $dir->file('whatever.sql')->touch;
    ok $tag = $plan->load_untracked( \@tags ),
      "Call load_untracked with $subdir";
    is $tag->dump, $exp->dump, "Files in $subdir should be ignored";
    remove_tree $dir->stringify;
}

# So now, make sure that load() results in the finding of untracked files.
isa_ok $plan = App::Sqitch::Plan->new(
    sqitch         => $sqitch,
    with_untracked => 1,
  ),
  $CLASS,
  'Plan with with_untracked';
is_deeply [ $plan->all ],
  [
    tag( [qw(foo)]     => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
    tag( ['HEAD+']     => [qw(bar baz yo stuff/wow)] ),
  ],
  'Plan should include untracked steps';
is_deeply $plan->load,
  [
    tag( [qw(foo)]     => [qw(hey you)] ),
    tag( [qw(bar baz)] => [qw(this/rocks hey-there)] ),
    tag( ['HEAD+']     => [qw(bar baz yo stuff/wow)] ),
  ],
  'load should also load untracked steps';

# Try to write a plan with a reserved tag name.
throws_ok { $plan->write_to($to) } qr/FAIL:/,
  'Should get an error writing a plan with untracked steps';
is_deeply +MockOutput->get_fail,
  [ ['Cannot write plan with reserved tag "HEAD+"'] ],
  'Should get error message about writing "HEAD+" tag';

##############################################################################
# Test open_script.
can_ok $CLASS, 'open_script';
my $step_file = file qw(sql deploy bar.sql);
my $fh = $step_file->open('>') or die "Cannot open $step_file: $!\n";
$fh->say('-- This is a comment');
$fh->say('# And so is this');
$fh->say('; and this, wee!');
$fh->say('/* blah blah blah */');
$fh->say('-- :requires: foo');
$fh->say('-- :requires: foo');
$fh->say('-- :requires:blah blah w00t');
$fh->say('-- :conflicts: yak');
$fh->say('-- :conflicts:this that');
$fh->close;
ok $fh = $plan->open_script(
    step => 'bar',
    dir  => $sqitch->deploy_dir
  ),
  'Open bar.sql';
is $fh->getline, "-- This is a comment\n", 'It should be the right file';
$fh->close;

ok $fh = $plan->open_script(
    step => 'baz',
    dir  => $sqitch->deploy_dir
  ),
  'Open baz.sql';
is $fh->getline, undef, 'It should be empty';

##############################################################################
# Test _parse_dependencies.
$mocker->unmock('_parse_dependencies');
can_ok $CLASS, '_parse_dependencies';
is_deeply $plan->_parse_dependencies( [], 'baz' ), {},
  'baz.sql should have no dependencies';

is_deeply $plan->_parse_dependencies( [], 'bar' ),
  {
    requires  => [qw(foo foo blah blah w00t)],
    conflicts => [qw(yak this that)],
  },
  'bar.sql should have a bunch of dependencies';

##############################################################################
# Test _sort_steps()
can_ok $CLASS, '_sort_steps';
my @deps;
$mocker->mock( _parse_dependencies => sub { shift @deps } );

# Start with no dependencies.
@deps = ( {}, {}, {} );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(this that other)], 'Should get original order when no dependencies';

# Have that require this.
@deps = ( {}, { requires => ['this'] }, {} );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(this that other)], 'Should get original order when that requires this';

# Have other require that.
@deps = ( {}, { requires => ['this'] }, { requires => ['that'] } );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(this that other)], 'Should get original order when other requires that';

# Have this require other.
@deps = ( { requires => ['other'] }, {}, {} );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(other this that)], 'Should get other first when this requires it';

# Have other other require taht.
@deps = ( { requires => ['other'] }, {}, { requires => ['that'] } );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(that other this)], 'Should get that, other, this now';

# Have this require other and that.
@deps = ( { requires => [ 'other', 'that' ] }, {}, {} );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(other that this)], 'Should get other, that, this now';

# Have this require other and that, and other requore that.
@deps = ( { requires => [ 'other', 'that' ] }, {}, { requires => ['that'] } );
is_deeply $plan->_sort_steps( ['foo'], {}, qw(this that other) ),
  [qw(that other this)], 'Should get that, other, this again';

# Add a cycle.
@deps = ( { requires => ['that'] }, { requires => ['this'] }, {} );
throws_ok { $plan->_sort_steps( ['foo'], {}, qw(this that other) ) } qr/FAIL:/,
  'Should get failure for a cycle';
is_deeply +MockOutput->get_fail,
  [ [ 'Dependency cycle detected beween steps "', 'this', ' and "that"', ] ],
  'The cylce should have been logged';

# Okay, now deal with depedencies from ealier tag sections.
@deps = ( { requires => ['foo'] }, {}, {} );
is_deeply $plan->_sort_steps( ['foo'], { foo => 1 }, qw(this that other) ),
  [qw(this that other)], 'Should get original order with earlier dependency';

# Mix it up.
@deps = ( { requires => [ 'other', 'that' ] }, { requires => ['sqitch'] }, {} );
is_deeply $plan->_sort_steps( ['foo'], { sqitch => 1 }, qw(this that other) ),
  [qw(other that this)], 'Should get other, that, this with earlier dependncy';

# Have a failed dependency.
# Okay, now deal with depedencies from ealier tag sections.
@deps = ( { requires => ['foo'] }, {}, {} );
throws_ok { $plan->_sort_steps( ['foo'], {}, qw(this that other) ) } qr/FAIL:/,
  'Should die on unknown dependency';
is_deeply +MockOutput->get_fail,
  [ [ 'Unknown step "foo" required in sql/deploy/this.sql' ] ],
  'And we should emit an error pointing to the offending script';
