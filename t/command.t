#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
#use Test::More tests => 135;
use Test::More 'no_plan';

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $catch_exit;
BEGIN {
    $catch_exit = 0;
    # Stub out exit.
    *CORE::GLOBAL::exit = sub {
        die 'EXITED: ' . (@_ ? shift : 0) if $catch_exit;
        CORE::exit(@_);
    };
}

use App::Sqitch;
use App::Sqitch::Target;
use Test::Exception;
use Test::NoWarnings;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use Capture::Tiny 0.12 ':all';
use Path::Class;
use lib 't/lib';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    load
    new
    options
    configure
    command
    prompt
    ask_y_n
    parse_args
    default_target
);

COMMAND: {
    # Stub out a couple of commands.
    package App::Sqitch::Command::whu;
    use Moo;
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

    package App::Sqitch::Command::wah_hoo;
    use Moo;
    extends 'App::Sqitch::Command';
    $INC{'App/Sqitch/Command/wah_hoo.pm'} = __FILE__;
}

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';

##############################################################################
# Test new().
throws_ok { $CLASS->new }
    qr/\QMissing required arguments: sqitch/,
    'Should get an exception for missing sqitch param';
my $array = [];
throws_ok { $CLASS->new({ sqitch => $array }) }
    qr/\QReference [] did not pass type constraint "Sqitch"/,
    'Should get an exception for array sqitch param';
throws_ok { $CLASS->new({ sqitch => 'foo' }) }
    qr/\QValue "foo" did not pass type constraint "Sqitch"/,
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
is_deeply $CLASS->configure($config, {'foo_bar' => 'yo'}), {foo => 'hi', foo_bar => 'yo'},
    'Options keys should have dashes changed to underscores';

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

# Test handling of nonexistent commands.
throws_ok { $CLASS->load({ command => 'nonexistent', sqitch => $sqitch }) }
    'App::Sqitch::X', 'Should exit';
is $@->ident, 'command', 'Nonexistent command error ident should be "config"';
is $@->message, __x(
    '"{command}" is not a valid command',
    command => 'nonexistent',
), 'Should get proper mesage for nonexistent command';
is $@->exitval, 1, 'Nonexistent command should yield exitval of 1';

# Test command that evals to a syntax error.
throws_ok {
    local $SIG{__WARN__} = sub { } if $] < 5.11; # Warns on 5.10.
    $CLASS->load({ command => 'foo.bar', sqitch => $sqitch })
} 'App::Sqitch::X', 'Should die on bad command';
is $@->ident, 'command', 'Bad command error ident should be "config"';
is $@->message, __x(
    '"{command}" is not a valid command',
    command => 'foo.bar',
), 'Should get proper mesage for bad command';
is $@->exitval, 1, 'Bad command should yield exitval of 1';

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
    'App::Sqitch::X', 'Should die on broken command module';
is $@->ident, 'command', 'Broken command error ident should be "config"';
is $@->message, __x(
    '"{command}" is not a valid command',
    command => 'bad',
), 'Should get proper mesage for broken command';
is $@->exitval, 1, 'Broken command should yield exitval of 1';

# Test options processing.
$cmock->mock(get_section => {foo => 'hi', feathers => 'yes'});
ok $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => $config,
    args    => ['--feathers' => 'no']
}), 'Load a "whu" command with "--feathers" optin';
is $cmd->feathers, 'no', 'The "feathers" attribute should be set';

# Test command with a dash in its name.
ok $cmd = $CLASS->load({
    command => 'wah-hoo',
    sqitch  => $sqitch,
    config  => $config,
}), 'Load a "wah-hoo" command';
isa_ok $cmd, "$CLASS\::wah_hoo", 'It';
is $cmd->command, 'wah-hoo', 'command() should return hyphenated name';

##############################################################################
# Test default_target.
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
isa_ok my $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:', 'Default target name should be "db:"';
is $target->uri, URI->new('db:'), 'Default target URI should be "db:"';

# Make sure the core.engine config option gets used.
my @get_ret;
my @get_expect;
$cmock->mock(get => sub {
    my $self = shift;
    my $exp = shift @get_expect;
    is_deeply \@_, [key => $exp], "Should try to fetch $exp";
    return shift @get_ret;
});
@get_ret = ('sqlite', 'sqlite');
@get_expect = ('core.engine', 'core.engine', 'core.sqlite.target');
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
isa_ok $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:sqlite:', 'Default target name should be "db:sqlite:"';
is $target->uri, URI->new('db:sqlite:'), 'Default target URI should be "db:sqlite:"';

# Make sure --engine is higher precedence.
$sqitch->options->{engine} = 'pg';
@get_expect = ('core.pg.target');
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
isa_ok $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:pg:', 'Default target name should be "db:pg:"';
is $target->uri, URI->new('db:pg:'), 'Default target URI should be "db:pg:"';

# We should get stuff from the engine section of the config.
@get_expect = ('core.pg.target');
@get_ret = ('db:pg:foo');
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
isa_ok $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:pg:foo', 'Default target name should be "db:pg:foo"';
is $target->uri, URI->new('db:pg:foo'), 'Default target URI should be "db:pg:foo"';

# Cleanup.
delete $sqitch->options->{engine};
$cmock->unmock('get');

##############################################################################
# Test command and execute.
can_ok $CLASS, 'execute';
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create a $CLASS object";
is $CLASS->command, '', 'Base class command should be ""';
is $cmd->command, '', 'Base object command should be ""';
throws_ok { $cmd->execute } 'App::Sqitch::X',
    'Should get an error calling execute on command base class';
is $@->ident, 'DEV', 'Execute exception ident should be "DEV"';
is $@->message, "The execute() method must be called from a subclass of $CLASS",
    'The execute() error message should be correct';

ok $cmd = App::Sqitch::Command::whu->new({sqitch => $sqitch}),
    'Create a subclass command object';
is $cmd->command, 'whu', 'Subclass oject command should be "whu"';
is +App::Sqitch::Command::whu->command, 'whu', 'Subclass class command should be "whu"';
throws_ok { $cmd->execute } 'App::Sqitch::X',
    'Should get an error for un-overridden execute() method';
is $@->ident, 'DEV', 'Un-overidden execute() exception ident should be "DEV"';
is $@->message, "The execute() method has not been overridden in $CLASS\::whu",
    'The unoverridden execute() error message should be correct';

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
    'foo'      => 1,
    'hi_there' => 1,
    'icky_foo' => 0,
    'feathers' => 'down',
}, 'Subclass should parse options spec';
is_deeply $args, ['whatever'], 'Args array should be cleared of options';

PARSEOPTSERR: {
    # Make sure that invalid options trigger an error.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; });
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
# Test argument passing.
ARGS: {
    local $ENV{SQITCH_CONFIG} = file qw(t local.conf);
    ok $sqitch = App::Sqitch->new(options => {
        engine    => 'sqlite',
        plan_file => file(qw(t plans multi.plan))->stringify,
        top_dir   => dir(qw(t sql))->stringify
    }), 'Load Sqitch with config and plan';

    ok my $cmd = $CLASS->new({ sqitch => $sqitch }), 'Load cmd with config and plan';
    my $parsem = sub {
        my %ret = $cmd->parse_args(@_);
        $ret{targets} = [ map { $_->name } @{ $ret{targets} } ];
        return \%ret;
    };

    is_deeply $parsem->(),
        { changes => [], targets => ['devdb'], unknown => [] },
        'Parsing now args should return no results';
    is_deeply $parsem->( args => ['foo'] ),
        { changes => [], targets => ['devdb'], unknown => ['foo'] },
        'Single unknown arg should be returned unknown';
    is_deeply $parsem->( args => ['hey'] ),
        { changes => ['hey'], targets => ['devdb'], unknown => [] },
        'Single change should be recognized as change';
    is_deeply $parsem->( args => ['devdb'] ),
        { changes => [], targets => ['devdb'], unknown => [] },
        'Single target should be recognized as target';
    is_deeply $parsem->(args => ['db:pg:']),
        { changes => [], targets => ['db:pg:'], unknown => [] },
        'URI target should be recognized as target, too';
    is_deeply $parsem->(args => ['devdb', 'hey']),
        { changes => ['hey'], targets => ['devdb'], unknown => [] },
        'Target and change should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb']),
        { changes => ['hey'], targets => ['devdb'], unknown => [] },
        'Change and target should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb', 'foo']),
        { changes => ['hey'], targets => ['devdb'], unknown => ['foo'] },
        'Change, target, and unknown should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb', 'foo', 'hey-there']),
        { changes => ['hey', 'hey-there'], targets => ['devdb'], unknown => ['foo'] },
        'Multiple changes, target, and unknown should be recognized';

    # Make sure changes are found in previously-passed target.
    ok $sqitch = App::Sqitch->new(options => {
        engine  => 'sqlite',
        top_dir => dir(qw(t sql))->stringify
    }), 'Load Sqitch with config';
    ok $cmd = $CLASS->new({ sqitch => $sqitch }), 'Load cmd with config';
    is_deeply $parsem->(args => ['mydb', 'you', 'add_user']),
        { changes => ['add_user'], targets => ['mydb'], unknown => ['you'] },
        'Change following target should be recognized from target plan';

    # Now pass a target.
    is_deeply $parsem->(target => 'devdb'),
        { changes => [], targets => ['devdb'], unknown => [] },
        'Passed target should always be returned';
    is_deeply $parsem->(target => 'devdb', args => ['mydb']),
        { changes => [], targets => ['devdb', 'mydb'], unknown => [] },
        'Passed and specified targets should always be returned';
    is_deeply $parsem->(target => 'devdb', args => ['hey']),
        { changes => [], targets => ['devdb'], unknown => ['hey'] },
        'Change unknown to passed target should be returned as unknown';
    is_deeply $parsem->(args => ['widgets', 'foo', '@beta']),
        { changes => ['widgets', '@beta'], targets => ['devdb'], unknown => ['foo'] },
        'Should get known changes from default target (t/sql/sqitch.plan)';
    is_deeply $parsem->(args => ['widgets', 'mydb', 'foo', '@beta']),
        { changes => ['widgets'], targets => ['devdb', 'mydb'], unknown => ['foo', '@beta'] },
        'Change seen after target should be unknown if not in that target';
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
$sqitch->{verbosity} = 3;
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other\n",
    'trace should work';
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->trace('This ', "that\n", 'and the other') },
    '', 'Should get no trace output for verbosity 2';

# Trace literal.
$sqitch->{verbosity} = 3;
is capture_stdout { $cmd->trace_literal('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other",
    'trace_literal should work';
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->trace_literal('This ', "that\n", 'and the other') },
    '', 'Should get no trace_literal output for verbosity 2';

# Debug.
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other\n",
    'debug should work';
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->debug('This ', "that\n", 'and the other') },
    '', 'Should get no debug output for verbosity 1';

# Debug literal.
$sqitch->{verbosity} = 2;
is capture_stdout { $cmd->debug_literal('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other",
    'debug_literal should work';
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->debug_literal('This ', "that\n", 'and the other') },
    '', 'Should get no debug_literal output for verbosity 1';

# Info.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'info should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->info('This ', "that\n", 'and the other') },
    '', 'Should get no info output for verbosity 0';

# Info literal.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->info_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'info_literal should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->info_literal('This ', "that\n", 'and the other') },
    '', 'Should get no info_literal output for verbosity 0';

# Comment.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $sqitch->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work with verbosity 0';

# Comment literal.
$sqitch->{verbosity} = 1;
is capture_stdout { $cmd->comment_literal('This ', "that\n", 'and the other') },
    "# This that\n# and the other",
    'comment_literal should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $sqitch->comment_literal('This ', "that\n", 'and the other') },
    "# This that\n# and the other",
    'comment_literal should work with verbosity 0';

# Emit.
is capture_stdout { $cmd->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work even with verbosity 0';

# Emit literal.
is capture_stdout { $cmd->emit_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'emit_literal should work';
$sqitch->{verbosity} = 0;
is capture_stdout { $cmd->emit_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'emit_literal should work even with verbosity 0';

# Warn.
is capture_stderr { $cmd->warn('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other\n",
    'warn should work';

# Warn literal.
is capture_stderr { $cmd->warn_literal('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other",
    'warn_literal should work';

# Usage.
$catch_exit = 1;
like capture_stderr {
    throws_ok { $cmd->usage('Invalid whozit') } qr/EXITED: 2/
}, qr/Invalid whozit/, 'usage should work';

like capture_stderr {
    throws_ok { $cmd->usage('Invalid whozit') } qr/EXITED: 2/
}, qr/\Qsqitch [<options>] <command> [<command-options>] [<args>]/,
    'usage should prefer sqitch-$command-usage';
