#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 178;
#use Test::More 'no_plan';
use Test::NoWarnings;
use List::Util qw(first);
use lib 't/lib';
use TestConfig;

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

my $config = TestConfig->new;
ok my $sqitch = App::Sqitch->new(config => $config), 'Load a sqitch object';

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
my $subclass = 'App::Sqitch::Command::whu';
is_deeply $subclass->configure($config, {}), {},
    'Should get empty hash for no config or options';
$config->update('whu.foo' => 'hi');
is_deeply $subclass->configure($config, {}), {foo => 'hi'},
    'Should get config with no options';
is_deeply $subclass->configure($config, {foo => 'yo'}), {foo => 'yo'},
    'Options should override config';
is_deeply $subclass->configure($config, {'foo_bar' => 'yo'}),
    {foo => 'hi', foo_bar => 'yo'},
    'Options keys should have dashes changed to underscores';

##############################################################################
# Test load().
$config = TestConfig->new;
ok $sqitch = App::Sqitch->new(config => $config), 'Load a sqitch object';
ok my $cmd = $CLASS->load({
    command => 'whu',
    sqitch  => $sqitch,
    config  => $config,
    args    => []
}), 'Load a "whu" command';
isa_ok $cmd, 'App::Sqitch::Command::whu';
is $cmd->sqitch, $sqitch, 'The sqitch attribute should be set';
is $cmd->command, 'whu', 'The command method should return "whu"';

$config->update('whu.foo' => 'hi');
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
$config->update('whu.feathers' => 'yes');
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
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object";
isa_ok my $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:', 'Default target name should be "db:"';
is $target->uri, URI->new('db:'), 'Default target URI should be "db:"';

# Track what gets passed to Config->get().
my (@get_expect, $orig_get);
my $cmock = TestConfig->mock(get => sub {
    my $self = shift;
    my $exp = shift @get_expect;
    is_deeply \@_, [key => $exp], "Should try to fetch $exp";
    $orig_get->($self, @_);
});
$orig_get = $cmock->original('get');

# Make sure the core.engine config option gets used.
@get_expect = ('core.engine', 'core.target', 'core.engine', 'engine.sqlite.target', 'core.sqlite.target');
$config->update('core.engine' => 'sqlite');
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object";
isa_ok $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:sqlite:', 'Default target name should be "db:sqlite:"';
is $target->uri, URI->new('db:sqlite:'), 'Default target URI should be "db:sqlite:"';

# Make sure --engine is higher precedence.
@get_expect = ('engine.pg.target', 'core.pg.target');
$sqitch->options->{engine} = 'pg';
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object";
isa_ok $target = $cmd->default_target, 'App::Sqitch::Target',
    'default target';
is $target->name, 'db:pg:', 'Default target name should be "db:pg:"';
is $target->uri, URI->new('db:pg:'), 'Default target URI should be "db:pg:"';

# We should get stuff from the engine section of the config.
@get_expect = ('engine.pg.target');
$config->update('engine.pg.target' => 'db:pg:foo');
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object";
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
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object";
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
ok $cmd = $CLASS->new({ sqitch => $sqitch }), "Create an $CLASS object again";
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
# Test argument parsing.
ARGS: {
    my $config = TestConfig->from(local => file qw(t local.conf) );
    $config->update('core.engine' => 'sqlite');
    ok $sqitch = App::Sqitch->new(
        config => $config,
        options => {
            plan_file => file(qw(t plans multi.plan))->stringify,
            top_dir   => dir(qw(t sql))->stringify
        },
    ), 'Load Sqitch with config and plan';

    ok my $cmd = $CLASS->load({
        sqitch => $sqitch,
        config => $config,
        command => 'whu',
    }), 'Load cmd with config and plan';
    my $parsem = sub {
        my @ret = $cmd->parse_args(@_);
        # Targets are always second to last.
        $ret[-2] = [ map { $_->name } @{ $ret[-2] } ];
        return \@ret;
    };

    my $msg = sub {
        __nx(
            'Unknown argument "{arg}"',
            'Unknown arguments: {arg}',
            scalar @_,
            arg => join ', ', @_
        )
    };

    is_deeply $parsem->(), [['devdb'], []],
        'Parsing no args should return default target';
    throws_ok { $parsem->( args => ['foo'] ) } 'App::Sqitch::X',
        'Single unknown arg raise an error';
    is $@->ident, 'whu', 'Unknown error ident should be "whu"';
    is $@->message, $msg->('foo'), 'Unknown error message should be correct';
    is_deeply $parsem->( args => ['hey'] ), [['devdb'], ['hey']],
        'Single change should be recognized as change';
    is_deeply $parsem->( args => ['devdb'] ),  [['devdb'], []],
        'Single target should be recognized as target';
    is_deeply $parsem->(args => ['db:pg:']),  [['db:pg:'], []],
        'URI target should be recognized as target, too';
    is_deeply $parsem->(args => ['devdb', 'hey']), [['devdb'], ['hey']],
        'Target and change should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb']), [['devdb'], ['hey']],
        'Change and target should be recognized';
    is_deeply $parsem->(args => ['mydb', 'hey']), [['mydb'], ['hey']],
        'Alternate Target and change should be recognized';
    is_deeply $parsem->(args => ['hey', 'mydb']), [['mydb'], ['hey']],
        'Change and alternate target should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb', 'foo'], names => [undef]),
        ['foo', ['devdb'], ['hey']],
        'Change, target, and unknown name should be recognized';
    is_deeply $parsem->(args => ['hey', 'devdb', 'foo', 'hey-there'], names => [0]),
        ['foo', ['devdb'], ['hey', 'hey-there']],
        'Multiple changes, target, and unknown name should be recognized';
    is_deeply $parsem->(args => ['yuck', 'hey', 'devdb', 'foo'], names => [0, 0]),
        ['yuck', 'foo', ['devdb'], ['hey']],
        'Multiple names should be recognized';
    throws_ok {
        $parsem->(args => ['yuck', 'hey', 'devdb'], names => ['hi']);
    } 'App::Sqitch::X', 'Should get an error with name and unknown';
    is $@->ident, 'whu', 'Unknown error ident should be "whu"';
    is $@->message, $msg->('yuck'), 'Unknown error message should be correct';
    throws_ok {
        $parsem->(args => ['yuck', 'hey', 'devdb', 'foo'], names => ['hi']);
    } 'App::Sqitch::X', 'Should get an error with name and two unknowns';
    is $@->ident, 'whu', 'Two unknowns error ident should be "whu"';
    is $@->message, $msg->('yuck', 'foo'),
        'Two unknowns error message should be correct';

    # Make sure changes are found in previously-passed target.
    ok $sqitch = App::Sqitch->new(
        config => $config,
        options => { top_dir => dir(qw(t sql))->stringify },
    ), 'Load Sqitch with config';
    ok $cmd = $CLASS->load({
        sqitch => $sqitch,
        command => 'whu',
        config => $config,
    }), 'Load cmd with config';
    is_deeply $parsem->(args => ['mydb', 'add_user']),
        [['mydb'], ['add_user']],
        'Change following target should be recognized from target plan';

    # Now pass a target.
    is_deeply $parsem->(target => 'devdb'), [['devdb'], []],
        'Passed target should always be returned';
    is_deeply $parsem->(target => 'devdb', args => ['mydb']),
         [['devdb', 'mydb'], []],
        'Passed and specified targets should always be returned';
    throws_ok {
        $parsem->(target => 'devdb', args => ['hey'])
    } 'App::Sqitch::X', 'Change unknown to passed target should error';
    is $@->ident, 'whu', 'Change unknown error ident should be "whu"';
    is $@->message, $msg->('hey'),
        'Change unknown error message should be correct';

    is_deeply $parsem->(args => ['sqlite', 'widgets', '@beta']),
        [['devdb'], ['widgets', '@beta']],
        'Should get known changes from default target (t/sql/sqitch.plan)';
    throws_ok {
        $parsem->(args => ['sqlite', 'widgets', 'mydb', 'foo', '@beta']);
    } 'App::Sqitch::X', 'Change seen after target should error if not in that target';
    is $@->ident, 'whu', 'Change after target error ident should be "whu"';
    is $@->message, $msg->('foo', '@beta'),
        'Change after target error message should be correct';

    # Make sure a plan file name is recognized as pointing to a target.
    is_deeply $parsem->(args => [file(qw(t plans dependencies.plan))->stringify]),
        [['mydb'], []], 'Should resolve plan file to a target';

    # Should work for default plan file, too.
    is_deeply $parsem->(args => [file(qw(t sql sqitch.plan))->stringify]),
        [['devdb'], []], 'SHould resolve default plan file to target';

    # Should also recognize an engine argument.
    is_deeply $parsem->(args => ['pg']), [['mydb'], []],
        'Should resolve engine "pg" file to its target';

    is_deeply $parsem->(args => ['sqlite']), [['devdb'], []],
        'Should resolve engine "sqlite" file to its target';

    # Try a bad target.
    throws_ok {
        $parsem->(args => [target => 'db:']);
    } 'App::Sqitch::X', 'Bad target should trigger error';
    is $@->ident, 'target', 'Bad target error ident should be "target"';
    is $@->message, __x(
        'No engine specified by URI {uri}; URI must start with "db:$engine:"',
        uri => 'db:',
    ), 'Should have bad target error message';

    # Make sure we don't get an error when the default target has no plan file.
    NOPLAN: {
        my $mock_target = Test::MockModule->new('App::Sqitch::Target');
        $mock_target->mock(plan_file => file 'no-such-file.txt');
        is_deeply $parsem->( args => ['devdb'] ),  [['devdb'], []],
            'Should recognize target when default target has no plan file';
    }

    # Make sure we get an error when no engine is specified.
    NOENGINE: {
        my $config = TestConfig->new;
        ok $sqitch = App::Sqitch->new(
            config => $config,
            options => {
                plan_file => file(qw(t plans multi.plan))->stringify,
                top_dir   => dir(qw(t sql))->stringify,
            },
        ), 'Load Sqitch without engine';

        ok $cmd = $CLASS->load({
            sqitch => $sqitch,
            config => $config,
            command => 'whu',
        }), 'Load cmd without engine';
        throws_ok { $parsem->() } 'App::Sqitch::X',
            'Should have error for no engine or target';
        is $@->ident, 'target', 'Should have target ident';
        is $@->message, __(
            'No engine specified; specify via target or core.engine',
        ), 'Should have message about no specified engine';

        # But it should be okay if we pass an engine or valid target.
        is_deeply $parsem->(args => ['pg']),
            [['db:pg:'], []],
            'Engine arg should override core target error';
        is_deeply $parsem->(args => ['db:sqlite:foo']),
            [['db:sqlite:foo'], []],
            'Target arg should override core target error';
    }
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
