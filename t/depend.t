#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 89;
#use Test::More 'no_plan';
use Test::Exception;
use Test::NoWarnings;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Depend';
    require_ok $CLASS or die;
}

can_ok $CLASS, qw(
    conflicts
    project
    change
    tag
    key_name
    as_string
    as_plan_string
);

for my $spec (
    [ 'foo'          => change => 'foo' ],
    [ 'bar'          => change => 'bar' ],
    [ '@bar'         => tag    => 'bar' ],
    [ '!foo'         => change => 'foo', conflicts => 1 ],
    [ '!@bar'        => tag    => 'bar', conflicts => 1 ],
    [ 'foo@bar'      => change => 'foo', tag => 'bar' ],
    [ '!foo@bar'     => change => 'foo', tag => 'bar', conflicts => 1 ],
    [ 'proj:foo'     => change => 'foo', project => 'proj' ],
    [ '!proj:foo'    => change => 'foo', project => 'proj', conflicts => 1 ],
    [ 'proj:@foo'    => tag    => 'foo', project => 'proj' ],
    [ '!proj:@foo'   => tag    => 'foo', project => 'proj', conflicts => 1 ],
    [ 'proj:foo@bar' => change => 'foo', tag     => 'bar', project => 'proj' ],
    [
        '!proj:foo@bar',
        change    => 'foo',
        tag       => 'bar',
        project   => 'proj',
        conflicts => 1
    ],
  )
{
    my $exp = shift @{$spec};
    ok my $depend = $CLASS->new( @{$spec} ), qq{Construct "$exp"};
    ( my $str = $exp ) =~ s/^!//;
    ( my $key = $str ) =~ s/^[^:]+://;
    is $depend->as_string, $str, qq{Parsed should stringify as "$str"};
    is $depend->key_name, $key, qq{Parsed should have key name "$key"};
    is $depend->as_plan_string, $exp, qq{Constructed should plan stringify as "$exp"};
    ok $depend = $CLASS->parse($exp), qq{Parse "$exp"};
    is $depend->as_plan_string, $exp, qq{Parsed should plan stringify as "$exp"};
}

for my $bad ( 'foo bar', 'foo+@bar', 'foo:+bar', 'foo@bar+', 'proj:foo@bar+', )
{
    is $CLASS->parse($bad), undef, qq{Should fail to parse "$bad"};
}

throws_ok { $CLASS->new } 'App::Sqitch::X',
  'Should get exception for no change or tag';
is $@->ident, 'DEV', 'No change or tag error ident should be "DEV"';
is $@->message,
  'Depend object must have either "change" or "tag" defined (or both)',
  'No change or tag error message should be correct';
