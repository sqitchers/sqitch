#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10.1;
use utf8;
#use Test::More tests => 220;
use Test::More 'no_plan';
use Test::Exception;
#use Test::NoWarnings;
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

my $id = '9ed961ad7902a67fe0804c8e49e8993719fd5065';
for my $spec(
    [ 'foo'      => change => 'foo' ],
    [ 'bar'      => change => 'bar' ],
    [ '@bar'     => tag    => 'bar' ],
    [ '!foo'     => change => 'foo', conflicts => 1 ],
    [ '!@bar'    => tag    => 'bar', conflicts => 1 ],
    [ 'foo@bar'  => change => 'foo', tag => 'bar' ],
    [ '!foo@bar' => change => 'foo', tag => 'bar', conflicts => 1 ],
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
    [ $id => id => $id ],
    [ "!$id"          => id     => $id, conflicts => 1 ],
    [ "foo:$id"       => id     => $id, project   => 'foo' ],
    [ "!foo:$id"      => id     => $id, project   => 'foo', conflicts => 1 ],
    [ "$id\@what"     => change => $id, tag       => 'what' ],
    [ "!$id\@what"    => change => $id, tag       => 'what', conflicts => 1 ],
    [ "foo:$id\@what" => change => $id, tag       => 'what', project => 'foo' ],
) {
    my $exp = shift @{$spec};
    ok my $depend = $CLASS->new(
        plan    => $plan,
        @{$spec},
    ), qq{Construct "$exp"};
    ( my $str = $exp ) =~ s/^!//;
    ( my $key = $str ) =~ s/^[^:]+://;
    my $proj = $1;
    is $depend->as_string, $str, qq{Constructed should stringify as "$str"};
    is $depend->key_name, $key, qq{Constructed should have key name "$key"};
    is $depend->as_plan_string, $exp, qq{Constructed should plan stringify as "$exp"};
    ok $depend = $CLASS->new(
        plan    => $plan,
        %{ $CLASS->parse($exp) },
    ), qq{Parse "$exp"};
    is $depend->as_plan_string, $exp, qq{Parsed should plan stringify as "$exp"};
    if ($str =~ /^([^:]+):/) {
        # Project specified in spec.
        my $prj = $1;
        ok $depend->got_project, qq{Should have got project from "$exp"};
        is $depend->project, $prj, qq{Should have project "$prj" for "$exp"};
        if ($prj eq $plan->project) {
            ok !$depend->is_external, qq{"$exp" should not be external};
            ok $depend->is_internal, qq{"$exp" should be internal};
        } else {
            ok $depend->is_external, qq{"$exp" should be external};
            ok !$depend->is_internal, qq{"$exp" should not be internal};
        }
    } else {
        ok !$depend->got_project, qq{Should not have got project from "$exp"};
        if ($depend->change || $depend->tag) {
            # No ID, default to current project.
            my $prj = $plan->project;
            is $depend->project, $prj, qq{Should have project "$prj" for "$exp"};
            ok !$depend->is_external, qq{"$exp" should not be external};
            ok $depend->is_internal, qq{"$exp" should be internal};
        } else {
            # ID specified, but no project, and ID not in plan, so unknown project.
            is $depend->project, undef, qq{Should have undef project for "$exp"};
            ok $depend->is_external, qq{"$exp" should be external};
            ok !$depend->is_internal, qq{"$exp" should not be internal};
        }
    }

    if ($exp =~ /\Q$id\E(?![@])/) {
        ok $depend->got_id, qq{Should have got ID from "$exp"};
    } else {
        ok !$depend->got_id, qq{Should not have got ID from "$exp"};
    }
}

for my $bad ( 'foo bar', 'foo+@bar', 'foo:+bar', 'foo@bar+', 'proj:foo@bar+', )
{
    is $CLASS->parse($bad), undef, qq{Should fail to parse "$bad"};
}

throws_ok { $CLASS->new( plan => $plan ) } 'App::Sqitch::X',
  'Should get exception for no change or tag';
is $@->ident, 'DEV', 'No change or tag error ident should be "DEV"';
is $@->message,
    'Depend object must have either "change", "tag", or "id" defined',
  'No change or tag error message should be correct';

for my $params (
    { change => 'foo' },
    { tag    => 'bar' },
    { change => 'foo', tag => 'bar' },
) {
    my $keys = join ' and ' => keys %{ $params };
    throws_ok { $CLASS->new( plan => $plan, id => $id, %{ $params} ) }
        'App::Sqitch::X', "Should get an error for ID + $keys";
    is $@->ident, 'DEV', qq{ID + $keys error ident ident should be "DEV"};
    is $@->message,
        'Depend object cannot contain both an ID and a tag or change',
        qq{ID + $keys error message should be correct};
}

##############################################################################
# Test ID.
ok my $depend = $CLASS->new(
    plan    => $plan,
    %{ $CLASS->parse('roles') },
), 'Create "roles" dependency';
is $depend->id, $plan->find('roles')->id,
    'Should find the "roles" ID in the plan';
ok !$depend->is_external, 'The "roles" change should not be external';
ok $depend->is_internal, 'The "roles" change should be internal';

ok $depend = $CLASS->new(
    plan    => $plan,
    %{ $CLASS->parse('elsewhere:roles') },
), 'Create "elsewhere:roles" dependency';
is $depend->id, undef, 'The "elsewhere:roles" id should be undef';
ok $depend->is_external, 'The "elsewhere:roles" change should be external';
ok !$depend->is_internal, 'The "elsewhere:roles" change should not be internal';

ok $depend = $CLASS->new(
    plan => $plan,
    id   => $id,
), 'Create depend using external ID';
is $depend->id, $id, 'The external ID should be set';
ok $depend->is_external, 'The external ID should register as external';
ok !$depend->is_internal, 'The external ID should not register as internal';

$id = $plan->find('roles')->id;
ok $depend = $CLASS->new(
    plan => $plan,
    id   => $id,
), 'Create depend using "roles" ID';
is $depend->id, $id, 'The "roles" ID should be set';
ok !$depend->is_external, 'The "roles" ID should not register as external';
ok $depend->is_internal, 'The "roles" ID should register as internal';

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
