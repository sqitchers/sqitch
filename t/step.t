#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 16;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use App::Sqitch::Plan::Tag;
use Path::Class;
use File::Path qw(make_path remove_tree);

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Step';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    tag
    deploy_file
    revert_file
    test_file
    requires
    conflicts
);

my $sqitch = App::Sqitch->new;
my $plan  = App::Sqitch::Plan->new(sqitch => $sqitch);
my $tag = App::Sqitch::Plan::Tag->new(
    names  => ['foo'],
    plan   => $plan,
);
isa_ok my $step = $CLASS->new(
    name => 'foo',
    tag  => $tag,
), $CLASS;

is $step->deploy_file, $sqitch->deploy_dir->file('foo.sql'),
    'The deploy file should be correct';
is $step->revert_file, $sqitch->revert_dir->file('foo.sql'),
    'The revert file should be correct';
is $step->test_file, $sqitch->test_dir->file('foo.sql'),
    'The test file should be correct';

##############################################################################
# Test _parse_dependencies.
can_ok $CLASS, '_parse_dependencies';

##############################################################################
# Test open_script.
make_path dir(qw(sql deploy))->stringify;
END { remove_tree 'sql' };
file(qw(sql deploy baz.sql))->touch;
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

ok $step = $CLASS->new( name => 'baz', tag  => $tag ),
    'Create step "baz"';

is_deeply $step->_parse_dependencies, { conflicts => [], requires => [] },
    'baz.sql should have no dependencies';
is_deeply [$step->requires], [], 'Requires should be empty';
is_deeply [$step->conflicts], [], 'Conflicts should be empty';

ok $step = $CLASS->new( name => 'bar', tag  => $tag ),
    'Create step "bar"';

is_deeply $step->_parse_dependencies([], 'bar'), {
    requires  => [qw(foo foo blah blah w00t)],
    conflicts => [qw(yak this that)],
},  'bar.sql should have a bunch of dependencies';
is_deeply [$step->requires], [qw(foo foo blah blah w00t)],
    'Requires get filled in';
is_deeply [$step->conflicts], [qw(yak this that)], 'Conflicts get filled in';
