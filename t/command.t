#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
use lib 't/lib';

BEGIN {
    # Stub out exit.
    *CORE::GLOBAL::exit = sub { die 'EXITED: ' . (@_ ? shift : 0); };
    $SIG{__DIE__} = \&Carp::confess;
}

use Test::More tests => 84;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Capture::Tiny ':all';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(load new options configure command);

COMMAND: {
    # Stub out a command.
    package App::Sqitch::Command::whu;
    use Moose;
    extends 'App::Sqitch::Command';
    has foo => (is => 'ro');
    has feathers => (is => 'ro');
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
    qr/\QAttribute (sqitch) is required/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new({ sqitch => $array }) }
    qr/\QValidation failed for 'App::Sqitch' with value $array/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new({ sqitch => 'foo' }) }
    qr/\QValidation failed for 'App::Sqitch' with value foo/,
    'Should get an exception for string sqitch param';

isa_ok $CLASS->new({sqitch => $sqitch}), $CLASS;

##############################################################################
# Test configure.
my $config = App::Sqitch::Config->new;
my $cmock = Test::MockModule->new('App::Sqitch::Config');
is_deeply $CLASS->configure($config, {}), {},
    'Should get empty hash for no config or options';
$cmock->mock(get_section => {foo => 'hi'});
is_deeply $CLASS->configure($config, {}), {foo => 'hi'},
    'Should get config with no options';
is_deeply $CLASS->configure($config, {foo => 'yo'}), {foo => 'yo'},
    'Options should override config';

##############################################################################
# Test load().
$cmock->mock(get_section => {});
ok my $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => $config,
    args    => []
}), 'Load a "whu" command';
isa_ok $cmd, 'App::Sqitch::Command::whu';
is $cmd->sqitch, $sqitch, 'The sqitch attribute should be set';

$cmock->mock(get_section => {foo => 'hi'});

ok $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => $config,
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

NOCOMMAND: {
    # Test handling of no command.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $CLASS->load({ command => '', sqitch => $sqitch }) }
        qr/USAGE/, 'No command should yield usage';
    is_deeply \@args, [$CLASS], 'No args should be passed to usage';
}

# Test handling a bad command implementation.
throws_ok { $CLASS->load({ command => 'bad', sqitch => $sqitch }) }
    qr/^LOL BADZ/, 'Should die on bad command module';

# Test options processing.
$cmock->mock(get_section => {foo => 'hi', feathers => 'yes'});
ok $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => $config,
    args    => ['--feathers' => 'no']
}), 'Load a "whu" command with "--feathers" optin';
is $cmd->feathers, 'no', 'The "feathers" attribute should be set';

##############################################################################
# Test command and execute.
can_ok $CLASS, 'execute';
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
is $CLASS->command, '', 'Base class command should be ""';
is $cmd->command, '', 'Base object command should be ""';
throws_ok { $cmd->execute }
    qr/\QThe execute() method must be called from a subclass of $CLASS/,
    'Should get an error calling execute on command base class';

ok $cmd = App::Sqitch::Command::whu->new({sqitch => $sqitch}),
    'Create a subclass command object';
is $cmd->command, 'whu', 'Subclass oject command should be "whu"';
is +App::Sqitch::Command::whu->command, 'whu', 'Subclass class command should be "whu"';
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

is_deeply $cmd->_parse_opts([1]), {}, 'Subclass should use options spec';
my $args = [qw(
    --foo
    --h
    --no-icky-foo
    --feathers down
    whatever
)];
is_deeply $cmd->_parse_opts($args), {
    foo      => 1,
    hi_there => 1,
    icky_foo => 0,
    feathers => 'down',
}, 'Subclass should parse options spec';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';

PARSEOPTSERR: {
    # Make sure that invalid options trigger an error.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(_pod2usage => sub { @args = @_} );
    my @warn; local $SIG{__WARN__} = sub { @warn = @_ };
    $cmd->_parse_opts(['--dont-do-this']);
    is_deeply \@warn, ["Unknown option: dont-do-this\n"],
        'Should get warning for unknown option';
    is_deeply \@args, [$cmd], 'Should call _pod2usage on options parse failure';

    # Try it with a command with no options.
    @args = @warn = ();
    isa_ok $cmd = App::Sqitch::Command->load({
        command => 'good',
        sqitch  => $sqitch,
        config  => $config,
    }), 'App::Sqitch::Command::good', 'Good command object';
    $cmd->_parse_opts(['--dont-do-this']);
    is_deeply \@warn, ["Unknown option: dont-do-this\n"],
        'Should get warning for unknown option when there are no options';
    is_deeply \@args, [$cmd], 'Should call _pod2usage on no options parse failure';
}

##############################################################################
# Test _pod2usage().
POD2USAGE: {
    my $mock = Test::MockModule->new('Pod::Usage');
    my %args;
    $mock->mock(pod2usage => sub { %args = @_} );
    $cmd = $CLASS->new({ sqitch => $sqitch });
    ok $cmd->_pod2usage, 'Call _pod2usage on base object';
    is_deeply \%args, {
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1}, 'sqitch'),
    }, 'Default params should be passed to Pod::Usage';

    $cmd = App::Sqitch::Command::whu->new({ sqitch => $sqitch });
    ok $cmd->_pod2usage, 'Call _pod2usage on "whu" command object';
    is_deeply \%args, {
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1}, 'sqitch'),
    }, 'Default params should be passed to Pod::Usage';

    isa_ok $cmd = App::Sqitch::Command->load({
        command => 'config',
        sqitch  => $sqitch,
        config  => $config,
    }), 'App::Sqitch::Command::config', 'Config command object';
    ok $cmd->_pod2usage, 'Call _pod2usage on "config" command object';
    is_deeply \%args, {
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch-config'),
    }, 'Should find sqitch-config docs to pass to Pod::Usage';

    isa_ok $cmd = App::Sqitch::Command->load({
        command => 'good',
        sqitch  => $sqitch,
        config  => $config,
    }), 'App::Sqitch::Command::good', 'Good command object';
    ok $cmd->_pod2usage, 'Call _pod2usage on "good" command object';
    is_deeply \%args, {
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch'),
    }, 'Should find App::Sqitch::Command::good docs to pass to Pod::Usage';

    # Test usage(), too.
    can_ok $cmd, 'usage';
    $cmd->usage('Hello ', 'gorgeous');
    is_deeply \%args, {
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch'),
        '-message'  => 'Hello gorgeous',
    }, 'Should find App::Sqitch::Command::good docs to pass to Pod::Usage';
}

##############################################################################
# Test verbosity.
can_ok $CLASS, 'verbosity';
is $cmd->verbosity, $sqitch->verbosity, 'Verbosity should be from sqitch';
$sqitch->{verbosity} = 3;
is $cmd->verbosity, $sqitch->verbosity, 'Verbosity should change with sqitch';

##############################################################################
# Test message levels. Start with trace.
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other\n",
    'trace should work';
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    '', 'Should get no trace output for verbosity 2';

# Debug.
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other\n",
    'debug should work';
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    '', 'Should get no debug output for verbosity 1';

# Info.
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'info should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    '', 'Should get no info output for verbosity 0';

# Comment.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->comment('This ', "that\n", 'and the other') },
    '', 'Should get no comment output for verbosity 0';

# Emit.
is capture_stdout { $cmd->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work even with verbosity 0';

# Warn.
is capture_stderr { $cmd->warn('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other\n",
    'warn should work';

# Fail.
is capture_stderr {
    throws_ok { $cmd->fail('This ', "that\n", "and the other") }
        qr/EXITED: 2/
}, "fatal: This that\nfatal: and the other\n",
    'fail should work';

# Unfound
is capture_stderr {
    throws_ok { $cmd->unfound } qr/EXITED: 1/
}, '', 'unfound print nothing';

# Help.
is capture_stderr {
    throws_ok { $cmd->help('This ', "that\n", "and the other.") }
        qr/EXITED: 1/
}, "sqch: This that\nsqch: and the other. See sqch --help\n",
    'help should work';

# Help.
is capture_stderr {
    throws_ok { $cmd->help('This ', "that\n", "and the other.") }
        qr/EXITED: 1/
}, "sqch: This that\nsqch: and the other. See sqch --help\n",
    'help should work';

##############################################################################
# Test do_system().
can_ok $CLASS, 'do_system';
is capture_stdout {
    ok $cmd->do_system(
        $^X, File::Spec->catfile(qw(t echo.pl)), qw(hi there)
    ), 'Should get success back from do_system echo';
}, "hi there\n", 'The echo script should have run';

is capture_stdout {
    ok !$cmd->do_system(
        $^X, File::Spec->catfile(qw(t die.pl)), qw(hi there)
    ), 'Should get fail back from do_system die';
}, "hi there\n", 'The die script should have run';
