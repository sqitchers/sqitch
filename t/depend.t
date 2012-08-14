#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
use Test::More tests => 98;
#use Test::More 'no_plan';
use Test::Exception;
use Test::NoWarnings;
use App::Sqitch;
use App::Sqitch::Plan;
use Locale::TextDomain qw(App-Sqitch);

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Plan::Depend';
    require_ok $CLASS or die;
}

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new(qw(t sql)),
), 'Load a sqitch sqitch object';
my $plan   = App::Sqitch::Plan->new(sqitch => $sqitch, project => 'depend');

can_ok $CLASS, qw(
    conflicts
    project
    change
    tag
    id
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
    ok my $depend = $CLASS->new(
        plan    => $plan,
        project => 'depend',
        @{$spec},
    ), qq{Construct "$exp"};
    ( my $str = $exp ) =~ s/^!//;
    ( my $key = $str ) =~ s/^[^:]+://;
    is $depend->as_string, $str, qq{Constructed should stringify as "$str"};
    is $depend->key_name, $key, qq{Constructed should have key name "$key"};
    is $depend->as_plan_string, $exp, qq{Constructed should plan stringify as "$exp"};
    ok $depend = $CLASS->new(
        plan    => $plan,
        project => 'depend',
        %{ $CLASS->parse($exp) },
    ), qq{Parse "$exp"};
    is $depend->as_plan_string, $exp, qq{Parsed should plan stringify as "$exp"};
}

for my $bad ( 'foo bar', 'foo+@bar', 'foo:+bar', 'foo@bar+', 'proj:foo@bar+', )
{
    is $CLASS->parse($bad), undef, qq{Should fail to parse "$bad"};
}

throws_ok { $CLASS->new( plan => $plan ) } 'App::Sqitch::X',
  'Should get exception for no change or tag';
is $@->ident, 'DEV', 'No change or tag error ident should be "DEV"';
is $@->message,
  'Depend object must have either "change" or "tag" defined (or both)',
  'No change or tag error message should be correct';

##############################################################################
# Test ID.
ok my $depend = $CLASS->new(
    plan    => $plan,
    project => $plan->project,
    %{ $CLASS->parse('roles') },
), 'Create "roles" dependency';
is $depend->id, $plan->find('roles')->id,
    'Should find the "roles" ID in the plan';

ok $depend = $CLASS->new(
    plan    => $plan,
    project => 'elsewhere',
    %{ $CLASS->parse('elsewhere:roles') },
), 'Create "elsewhere:roles" dependency';
is $depend->id, undef, 'The "elsewhere:roles" id should be undef';

ok $depend = $CLASS->new(
    plan    => $plan,
    project => $plan->project,
    %{ $CLASS->parse('nonexistent') },
), 'Create "nonexistent" dependency';
throws_ok { $depend->id } 'App::Sqitch::X',
    'Should get error for nonexistent change';
is $@->ident, 'plan', 'Nonexistent change error ident should be "plan"';
is $@->message, __x(
    'Unable to find change "{change}" in plan {file}',
    change => 'nonexistent',
    file   => $plan->sqitch->plan_file,
), 'Nonexistent change error message should be correct';
