#!/usr/bin/perl -w

use strict;
use Test::More;
use Test::Exception;
use Try::Tiny;
use Path::Class;

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

# Make sure default ident works.
ok $x = $CLASS->new(message => 'whatever'), 'Create X without ident';
is $x->ident, 'DEV', 'Default ident should be "DEV"';

throws_ok { hurl basic => 'OMFG!' } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->ident, 'basic', 'Ident should be "basic"';
is $x->message, 'OMFG!', 'The message should have been passed';
ok $x->stack_trace->frames, 'It should have a stack trace';
is $x->exitval, 2, 'Exit val should be 2';
is +($x->stack_trace->frames)[0]->filename, file(qw(t x.t)),
    'The trace should start in this file';

throws_ok { hurl 'OMFG!' } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->ident, 'DEV', 'Ident should be "DEV"';
is $x->message, 'OMFG!', 'The message should have been passed';
is $x->exitval, 2, 'Exit val should again be 2';

throws_ok { hurl {ident => 'blah', message => 'OMFG!', exitval => 1} } $CLASS;
isa_ok $x = $@, $CLASS, 'Thrown object';
is $x->message, 'OMFG!', 'The params should have been passed';
is $x->exitval, 1, 'Exit val should be 1';
is $x->as_string, join($/, grep { defined }
    $x->message,
    $x->previous_exception,
    $x->stack_trace
), 'Stringification should work';

is $x->as_string, "$x", 'Stringification should work';

# Do some actual exception handling.
try {
    hurl io => 'Cannot open file';
} catch {
    return fail "Not a Sqitch::X: $_" unless eval { $_->isa('App::Sqitch::X') };
    is $_->ident, 'io', 'Should be an "io" exception';
};

done_testing;
