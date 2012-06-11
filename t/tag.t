#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 10;
#use Test::More 'no_plan';
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use Test::MockModule;
use Digest::SHA1;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Tag';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    name
    lspace
    rspace
    comment
    plan
);

my $sqitch = App::Sqitch->new;
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch);
isa_ok my $tag = $CLASS->new(
    name  => 'foo',
    plan  => $plan,
), $CLASS;
isa_ok $tag, 'App::Sqitch::Plan::Line';

is $tag->format_name, '@foo', 'Name should format as "@foo"';
is $tag->stringify, '@foo', 'Should stringify to "@foo"';

ok $tag = $CLASS->new(
    name    => 'howdy',
    plan    => $plan,
    lspace  => '  ',
    rspace  => "\t",
    comment => ' blah blah blah',
), 'Create tag with more stuff';

is $tag->stringify, "  \@howdy\t# blah blah blah",
    'It should stringify correctly';

my $mock_plan = Test::MockModule->new('App::Sqitch::Plan');
$mock_plan->mock(index_of => 0);

is $tag->id, do {
    my $content = join "\n", (
        'object 0000000000000000000000000000000000000000',
        'type tag',
        'tag @howdy',
        );
    Digest::SHA1->new->add(
        'tag ' . length $content . "\0" . $content
    )->hexdigest;
},'Tag SHA1 should be correct';
