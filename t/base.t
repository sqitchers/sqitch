#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 77;
#use Test::More 'no_plan';
use Test::MockModule;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Capture::Tiny ':all';
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X 'hurl';

BEGIN {
    # Stub out exit.
    *CORE::GLOBAL::exit = sub { die 'EXITED: ' . (@_ ? shift : 0); };
    $SIG{__DIE__} = \&Carp::confess;
}

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    go
    new
    plan_file
    plan
    engine
    _engine
    client
    db_name
    username
    host
    port
    top_dir
    deploy_dir
    revert_dir
    test_dir
    extension
    verbosity
);

##############################################################################
# Defaults.
isa_ok my $sqitch = $CLASS->new, $CLASS, 'A new object';

for my $attr (qw(
    _engine
    engine
    client
    username
    db_name
    host
    port
)) {
    is $sqitch->$attr, undef, "$attr should be undef";
}

is $sqitch->plan_file, $sqitch->top_dir->file('sqitch.plan')->cleanup,
    'Default plan file should be $top_dir/sqitch.plan';
is $sqitch->verbosity, 1, 'verbosity should be 1';
is $sqitch->extension, 'sql', 'Default extension should be sql';
is $sqitch->top_dir, dir(), 'Default top_dir should be .';
is $sqitch->deploy_dir, dir(qw(deploy)), 'Default deploy_dir should be ./sql/deploy';
is $sqitch->revert_dir, dir(qw(revert)), 'Default revert_dir should be ./sql/revert';
is $sqitch->test_dir, dir(qw(test)), 'Default test_dir should be ./sql/test';
isa_ok $sqitch->plan, 'App::Sqitch::Plan';
throws_ok { $sqitch->uri } 'App::Sqitch::X',
    'Should get error for missing URI';
is $@->ident, 'core', 'Should be a "core" exception';
is $@->message, __x(
    'Missing project URI. Run {command} to add a URI',
    command => '`sqitch config core.uri URI`'
), 'Should have localized error message about missing URI';

##############################################################################
# Test go().
GO: {
    my $mock = Test::MockModule->new('App::Sqitch::Command::help');
    my ($cmd, @params);
    my $ret = 1;
    $mock->mock(execute => sub { ($cmd, @params) = @_; $ret });
    chdir 't';
    local $ENV{SQITCH_USER_CONFIG} = 'user.conf';
    local @ARGV = qw(--engine sqlite help config);
    is +App::Sqitch->go, 0, 'Should get 0 from go()';

    isa_ok $cmd, 'App::Sqitch::Command::help', 'Command';
    is_deeply \@params, ['config'], 'Extra args should be passed to execute';

    isa_ok my $sqitch = $cmd->sqitch, 'App::Sqitch';
    is $sqitch->_engine, 'sqlite', 'Engine should be set by option';
    # isa $sqitch->engine, 'App::Sqitch::Engine::sqlite',
    #     'Engine object should be constructable';
    is $sqitch->extension, 'ddl', 'ddl should be set by config';
    ok my $config = $sqitch->config, 'Get the Sqitch config';
    is $config->get(key => 'core.pg.client'), '/usr/local/pgsql/bin/psql',
        'Should have local config overriding user';
    is $config->get(key => 'core.pg.host'), 'localhost',
        'Should fall back on user config';
    is $sqitch->uri, URI->new('https://github.com/theory/sqitch/'),
        'Should read URI from config file';

    # Now make it die.
    sub puke { App::Sqitch::X->new(@_) } # Ensures we have trace frames.
    my $ex = puke(ident => 'ohai', message => 'OMGWTF!');
    $mock->mock(execute => sub { die $ex });
    my $sqitch_mock = Test::MockModule->new($CLASS);
    my @vented;
    $sqitch_mock->mock(vent => sub { push @vented => $_[1]; });
    my $traced;
    $sqitch_mock->mock(trace => sub { $traced = $_[1]; });
    is $sqitch->go, 2, 'Go should return 2 on Sqitch exception';
    is_deeply \@vented, ['OMGWTF!'], 'The error should have been vented';
    is $traced, $ex->stack_trace->as_string,
        'The stack trace should have been sent to trace';

    # Make it die with a developer exception.
    @vented = ();
    $traced = undef;
    $ex = puke( message => 'OUCH!', exitval => 4 );
    is $sqitch->go, 4, 'Go should return exitval on another exception';
    is_deeply \@vented, ['OUCH!', $ex->stack_trace->as_string],
        'Both the message and the trace should have been vented';
    is $traced, undef, 'Nothing should have been traced';

    # Make it die without an exception object.
    $ex = 'LOLZ';
    @vented = ();
    is $sqitch->go, 2, 'Go should return 2 on a third Sqitch exception';
    is @vented, 1, 'Should have one thing vented';
    like $vented[0], qr/^LOLZ\b/, 'And it should include our message';
}

##############################################################################
# Test the editor.
EDITOR: {
    local $ENV{EDITOR} = 'edd';
    my $sqitch = App::Sqitch->new({editor => 'emacz' });
    is $sqitch->editor, 'emacz', 'editor should use use parameter';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'edd', 'editor should use $EDITOR';

    local $ENV{SQITCH_EDITOR} = 'vimz';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'vimz', 'editor should prefer $SQITCH_EDITOR';

    delete $ENV{SQITCH_EDITOR};
    delete $ENV{EDITOR};
    local $^O = 'NotWin32';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'vi', 'editor fall back on vi when not Windows';

    $^O = 'MSWin32';
    $sqitch = App::Sqitch->new;
    is $sqitch->editor, 'notepad.exe', 'editor fall back on notepad on Windows';
}

##############################################################################
# Test message levels. Start with trace.
$sqitch = $CLASS->new(verbosity => 3);
is capture_stdout { $sqitch->trace('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other\n",
    'trace should work';
$sqitch = $CLASS->new(verbosity => 2);
is capture_stdout { $sqitch->trace('This ', "that\n", 'and the other') },
    '', 'Should get no trace output for verbosity 2';

# Debug.
is capture_stdout { $sqitch->debug('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other\n",
    'debug should work';
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->debug('This ', "that\n", 'and the other') },
    '', 'Should get no debug output for verbosity 1';

# Info.
is capture_stdout { $sqitch->info('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'info should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->info('This ', "that\n", 'and the other') },
    '', 'Should get no info output for verbosity 0';

# Comment.
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->comment('This ', "that\n", 'and the other') },
    '', 'Should get no comment output for verbosity 0';

# Emit.
is capture_stdout { $sqitch->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work even with verbosity 0';

# Warn.
is capture_stderr { $sqitch->warn('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other\n",
    'warn should work';

# Vent.
is capture_stderr { $sqitch->vent('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'vent should work';

##############################################################################
# Test run().
can_ok $CLASS, 'run';
my ($stdout, $stderr) = capture {
    ok $sqitch->run(
        $^X, 'echo.pl', qw(hi there)
    ), 'Should get success back from run echo';
};

is $stdout, "hi there\n", 'The echo script should have run';
is $stderr, '', 'Nothign should have gone to STDERR';

($stdout, $stderr) = capture {
    throws_ok {
        $sqitch->run( $^X, 'die.pl', qw(hi there))
    } qr/unexpectedly returned/, 'run die should, well, die';
};

is $stdout, "hi there\n", 'The die script should have its STDOUT ummolested';
like $stderr, qr/OMGWTF/, 'The die script should have its STDERR unmolested';

##############################################################################
# Test capture().
can_ok $CLASS, 'capture';
is $sqitch->capture($^X, 'echo.pl', qw(hi there)),
    "hi there\n", 'The echo script output should have been returned';
like capture_stderr {
    throws_ok { $sqitch->capture($^X, 'die.pl', qw(hi there)) }
        qr/unexpectedly returned/,
        'Should get an error if the command errors out';
}, qr/OMGWTF/m, 'The die script STDERR should have passed through';

##############################################################################
# Test probe().
can_ok $CLASS, 'probe';
is $sqitch->probe($^X, 'echo.pl', qw(hi there), "\nyo"),
    "hi there ", 'Should have just chomped first line of output';

##############################################################################
# Test spool().
can_ok $CLASS, 'spool';
my $data = "hi\nthere\n";
open my $fh, '<', \$data;
is capture_stdout {
    ok $sqitch->spool($fh, $^X, 'read.pl'), 'Spool to read.pl';
}, $data, 'Data should have been sent to STDOUT by read.pl';
like capture_stderr {
    throws_ok { $sqitch->spool($fh, $^X, 'die.pl') }
        qr/\Q$^X\E unexpectedly returned exit value /,
        'Should get error when die.pl dies';
}, qr/OMGWTF/, 'The die script STDERR should have passed through';

throws_ok { $sqitch->spool($fh, '--nosuchscript.ply--') }
    qr/\QCannot exec --nosuchscript.ply--: No such file/,
    'Should get an error for a bad command';
