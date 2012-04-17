#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
use lib 't/lib';

BEGIN {
    # Stub out exit.
    *CORE::GLOBAL::exit = sub { die 'EXITED: ' . (@_ ? shift : 0); };
}

#use Test::More tests => 35;
use Test::More 'no_plan';
use App::Sqitch;
use Test::Exception;
use Test::NoWarnings;
use Capture::Tiny ':all';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(load new);

COMMAND: {
    # Stub out a command.
    package App::Sqitch::Command::whu;
    use parent 'App::Sqitch::Command';
    __PACKAGE__->mk_accessors('foo');
    $INC{'App/Sqitch/Command/whu.pm'} = __FILE__;

    sub options {
        return qw(
            foo
            hi-there|h
            icky-foo!
            feathers=s
        );
    }

}

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';

##############################################################################
# Test new().
throws_ok { $CLASS->new }
    qr/No "sqitch" parameter passed to App::Sqitch::Command->new/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new({ sqitch => $array }) }
    qr/\Q$array is not an App::Sqitch object/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new({ sqitch => 'foo' }) }
    qr/foo is not an App::Sqitch object/,
    'Should get an exception for string sqitch param';

isa_ok $CLASS->new({sqitch => $sqitch}), $CLASS;

##############################################################################
# Test load().
ok my $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => {},
    args    => []
}), 'Load a "whu" command';
isa_ok $cmd, 'App::Sqitch::Command::whu';
is $cmd->sqitch, $sqitch, 'The sqitch attribute should be set';

ok $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => {foo => 'hi'},
    args    => []
}), 'Load a "whu" command with "foo" config';
is $cmd->foo, 'hi', 'The "foo" attribute should be set';

# Test handling of an invalid command.
$0 = 'sqch';
is capture_stderr {
    throws_ok { $CLASS->load({ command => 'nonexistent', sqitch => $sqitch }) }
        qr/EXITED: 1/, 'Should exit';
 }, qq{sqch: "nonexistent" is not a valid command. See sqch --help\n},
    'Should get an exception for an invalid command';

# Test handling a bad command implementation.
throws_ok { $CLASS->load({ command => 'bad', sqitch => $sqitch }) }
    qr/^LOL BADZ/, 'Should die on bad command module';

##############################################################################
# Test execute.
can_ok $CLASS, 'execute';
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
throws_ok { $cmd->execute }
    qr/\QThe execute() method must be called from a subclass of $CLASS/,
    'Should get an error calling execute on command base class';

ok $cmd = App::Sqitch::Command::whu->new({sqitch => $sqitch}),
    'Create a subclass command object';
throws_ok { $cmd->execute }
    qr/\QThe execute() method has not been overridden in App::Sqitch::Command::whu/,
    'Should get an error for un-overridden execute() method';

##############################################################################
# Test options parsing.
can_ok $CLASS, 'options', '_parse_opts';
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object again";
is_deeply $cmd->_parse_opts, {}, 'Base _parse_opts should return an empty hash';

ok $cmd = App::Sqitch::Command::whu->new({sqitch => $sqitch}),
    'Create a subclass command object again';
is_deeply $cmd->_parse_opts, {}, 'Subclass should return an empty hash for no args';

my %opts = (
    foo      => undef,
    hi_there => undef,
    icky_foo => undef,
    feathers => undef,
);
is_deeply $cmd->_parse_opts([1]), \%opts, 'Subclass should use options spec';
is_deeply $cmd->_parse_opts([qw(
    --foo
    --h
    --no-icky-foo
    --feathers down
)]), {
    foo      => 1,
    hi_there => 1,
    icky_foo => 0,
    feathers => 'down',
}, 'Subclass should parse options spec';

##############################################################################
# Test verbosity.
can_ok $CLASS, 'verbosity';
is $cmd->verbosity, $sqitch->verbosity, 'Verbosity should be from sqitch';
$sqitch->{verbosity} = 3;
is $cmd->verbosity, $sqitch->verbosity, 'Verbosity should change with sqitch';

##############################################################################
# Test message levels. Start with trace.
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other",
    'trace should work';
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    '', 'Should get no trace output for verbosity 2';

# Debug.
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other",
    'debug should work';
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    '', 'Should get no debug output for verbosity 1';

# Info.
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    '', 'Should get no info output for verbosity 0';

# Comment.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other",
    'comment should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->comment('This ', "that\n", 'and the other') },
    '', 'Should get no comment output for verbosity 0';

# Warn.
is capture_stderr { $cmd->warn('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other",
    'warn should work';

# Fail.
is capture_stderr {
    throws_ok { $cmd->fail('This ', "that\n", "and the other") }
        qr/EXITED: 1/
}, "fatal: This that\nfatal: and the other",
    'fail should work';

# Help.
is capture_stderr {
    throws_ok { $cmd->help('This ', "that\n", "and the other.") }
        qr/EXITED: 1/
}, "sqch: This that\nsqch: and the other. See sqch --help\n",
    'help should work';

