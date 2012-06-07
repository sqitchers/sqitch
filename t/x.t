#!/usr/bin/perl -w

use strict;
use Test::More;
use Test::Exception;
use Try::Tiny;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::X';
    require_ok $CLASS or die;
    $CLASS->import(':all');
}


isa_ok my $x = $CLASS->new(ident => 'test', message => 'Die'), $CLASS, 'X object';

for my $role(qw(
    Throwable
    Role::HasMessage
    StackTrace::Auto
    Role::Identifiable::HasIdent
)) {
    ok $x->does($role), "X object does $role";
}

throws_ok { hurl basic => 'OMFG!' } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->ident, 'basic', 'Ident should be "basic"';
is $x->message, 'OMFG!', 'The message should have been passed';
ok $x->stack_trace->frames, 'It should have a stack trace';
is +($x->stack_trace->frames)[0]->filename, __FILE__,
    'The trace should start in this file';

throws_ok { hurl 'OMFG!' } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->ident, 'OMFG!', 'Ident should be "OMFG!"';
is $x->message, 'OMFG!', 'The message should have been passed';

throws_ok { hurl {ident => 'blah', message => 'OMFG!'} } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->message, 'OMFG!', 'The params should have been passed';

# Do some actual exception handling.
try {
    hurl io => 'Cannot open file';
} catch {
    return fail "Not a Sqitch::X: $_" unless eval { $_->isa('App::Sqitch::X') };
    is $_->ident, 'io', 'Should be an "io" exception';
};

done_testing;
