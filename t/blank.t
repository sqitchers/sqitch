#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 14;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Blank';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    note
    plan
);

my $sqitch = App::Sqitch->new;
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $blank = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
), $CLASS;
isa_ok $blank, 'App::Sqitch::Plan::Line';

is $blank->format_name, '', 'Name should format as ""';
is $blank->as_string, '', 'should stringify to ""';

ok $blank = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    lspace  => '  ',
    rspace  => "\t",
    note   => 'blah blah blah',
), 'Create tag with more stuff';

is $blank->as_string, "  \t# blah blah blah",
    'It should stringify correctly';

ok $blank = $CLASS->new(plan => $plan, note => "foo\nbar\nbaz\\\n"),
    'Create a blank with newlines and backslashes in the note';
is $blank->note, "foo\nbar\nbaz\\\n",
    'The newlines and backslashe should not be escaped';

is $blank->format_note, '# foo\\nbar\\nbaz\\\\\\n',
    'The newlines and backslahs should be escaped by format_note';

ok $blank = $CLASS->new(plan => $plan, note => "foo\\nbar\\nbaz\\\\\\n"),
    'Create a blank with escapes';
is $blank->note, "foo\nbar\nbaz\\\n", 'Note shoud be unescaped';
