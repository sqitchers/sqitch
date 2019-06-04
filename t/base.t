#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 189;
#use Test::More 'no_plan';
use Test::MockModule 0.17;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Capture::Tiny 0.12 qw(:all);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X 'hurl';
use lib 't/lib';
use TestConfig;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    go
    new
    options
    user_name
    user_email
    verbosity
    prompt
    ask_yes_no
    ask_y_n
);

##############################################################################
# Overrides.
my $config = TestConfig->new;
$config->data({'core.verbosity' => 2});
isa_ok my $sqitch = $CLASS->new({ config => $config, options => {} }),
    $CLASS, 'A configured object';

is $sqitch->verbosity, 2, 'Configured verbosity should override default';

isa_ok $sqitch = $CLASS->new({ config => $config, options => {verbosity => 3} }),
    $CLASS, 'A configured object';

is $sqitch->verbosity, 3, 'Verbosity option should override configuration';

##############################################################################
# Defaults.
$config->replace;
isa_ok $sqitch = $CLASS->new(config => $config), $CLASS, 'A new object';

is $sqitch->verbosity, 1, 'Default verbosity should be 1';
ok $sqitch->sysuser, 'Should have default sysuser from system';
ok $sqitch->user_name, 'Default user_name should be set from system';
is $sqitch->user_email, do {
    require Sys::Hostname;
    $sqitch->sysuser . '@' . Sys::Hostname::hostname();
}, 'Default user_email should be set from system';

##############################################################################
# User environment variables.
ENV: {
    # Try originating host variables.
    local $ENV{SQITCH_ORIG_SYSUSER} = "__kamala__";
    local $ENV{SQITCH_ORIG_FULLNAME} = 'Kamala Harris';
    local $ENV{SQITCH_ORIG_EMAIL} = 'kamala@whitehouse.gov';
    isa_ok $sqitch = $CLASS->new(config => $config), $CLASS, 'Another new object';
    is $sqitch->sysuser, $ENV{SQITCH_ORIG_SYSUSER},
        "SQITCH_ORIG_SYSUER should override system username";
    is $sqitch->user_name, $ENV{SQITCH_ORIG_FULLNAME},
        "SQITCH_ORIG_FULLNAME should override system user full name";
    is $sqitch->user_email, $ENV{SQITCH_ORIG_EMAIL},
        "SQITCH_ORIG_EMAIL should override system-derived email";

    # Local variables take precedence over originating host variables.
    local $ENV{SQITCH_FULLNAME} = 'Barack Obama';
    local $ENV{SQITCH_EMAIL} = 'barack@whitehouse.gov';
    isa_ok $sqitch = $CLASS->new, $CLASS, 'Another new object';
    is $sqitch->user_name, $ENV{SQITCH_FULLNAME},
        "SQITCH_FULLNAME should override originating host user full name";
    is $sqitch->user_email, $ENV{SQITCH_EMAIL},
        "SQITCH_EMAIL should override originating host email";
}

##############################################################################
# Test go().
GO: {
    local $ENV{SQITCH_ORIG_SYSUSER} = "__barack__";
    local $ENV{SQITCH_ORIG_FULLNAME} = 'Barack Obama';
    local $ENV{SQITCH_ORIG_EMAIL} = 'barack@whitehouse.gov';

    my $mock = Test::MockModule->new('App::Sqitch::Command::help');
    my ($cmd, @params);
    my $ret = 1;
    $mock->mock(execute => sub { ($cmd, @params) = @_; $ret });
    chdir 't';

    my $config = TestConfig->from(
        local => 'sqitch.conf',
        user  => 'user.conf',
    );

    my $mocker = Test::MockModule->new('App::Sqitch::Config');
    $mocker->mock(new => $config);

    local @ARGV = qw(help config);
    is +App::Sqitch->go, 0, 'Should get 0 from go()';

    isa_ok $cmd, 'App::Sqitch::Command::help', 'Command';
    is_deeply \@params, ['config'], 'Extra args should be passed to execute';

    isa_ok my $sqitch = $cmd->sqitch, 'App::Sqitch';
    ok $config = $sqitch->config, 'Get the Sqitch config';
    is $config->get(key => 'engine.pg.client'), '/usr/local/pgsql/bin/psql',
        'Should have local config overriding user';
    is $config->get(key => 'engine.pg.registry'), 'meta',
        'Should fall back on user config';
    is $sqitch->user_name, 'Michael Stonebraker',
        'Should have read user name from configuration';
    is $sqitch->user_email, 'michael@example.com',
        'Should have read user email from configuration';
    is_deeply $sqitch->options, { }, 'Should have no options';

    # Make sure USER_NAME and USER_EMAIL take precedence over configuration.
    local $ENV{SQITCH_FULLNAME} = 'Michelle Obama';
    local $ENV{SQITCH_EMAIL} = 'michelle@whitehouse.gov';
    is +App::Sqitch->go, 0, 'Should get 0 from go() again';
    isa_ok $sqitch = $cmd->sqitch, 'App::Sqitch';
    is $sqitch->user_name, 'Michelle Obama',
        'Should have read user name from environment';
    is $sqitch->user_email, 'michelle@whitehouse.gov',
        'Should have read user email from environment';

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
    local $ENV{SQITCH_EDITOR};
    local $ENV{VISUAL};

    local $ENV{EDITOR} = 'edd';
    my $sqitch = App::Sqitch->new(config => $config);
    is $sqitch->editor, 'edd', 'editor should use $EDITOR';

    local $ENV{VISUAL} = 'gvim';
    $sqitch = App::Sqitch->new(config => $config);
    is $sqitch->editor, 'gvim', 'editor should prefer $VISUAL over $EDITOR';

    my $config = TestConfig->from(local => 'editor.conf');
    $sqitch = App::Sqitch->new(config => $config);
    is $sqitch->editor, 'config_specified_editor', 'editor should prefer core.editor over $VISUAL';

    local $ENV{SQITCH_EDITOR} = 'vimz';
    $sqitch = App::Sqitch->new(config => $config);
    is $sqitch->editor, 'vimz', 'editor should prefer $SQITCH_EDITOR over $VISUAL';

    $sqitch = App::Sqitch->new({editor => 'emacz' });
    is $sqitch->editor, 'emacz', 'editor should use use parameter regardless of environment';

    delete $ENV{SQITCH_EDITOR};
    delete $ENV{VISUAL};
    delete $ENV{EDITOR};
    $config->replace;
    $sqitch = App::Sqitch->new(config => $config);
    if (App::Sqitch::ISWIN) {
        is $sqitch->editor, 'notepad.exe', 'editor fall back on notepad on Windows';
    } else {
        is $sqitch->editor, 'vi', 'editor fall back on vi when not Windows';
    }
}

##############################################################################
# Test the pager program config. We want to pick up from one of the following
# places, earlier in the list more preferred.
# - SQITCH_PAGER environment variable.
# - core.pager configuration prop.
# - PAGER environment variable.
#
PAGER_PROGRAM: {
    # Ignore warnings while loading IO::Pager.
    { local $SIG{__WARN__} = sub {}; require IO::Pager }

    # Mock the IO::Pager constructor.
    my $mock_pager = Test::MockModule->new('IO::Pager');
    $mock_pager->mock(new => sub { return bless => {} => 'IO::Pager' });

    # No pager if no TTY.
    my $pager_class = -t *STDOUT ? 'IO::Pager' : 'IO::Handle';
    {
        local $ENV{SQITCH_PAGER};
        local $ENV{PAGER} = "morez";
        my $sqitch = App::Sqitch->new(config => $config);
        is $sqitch->pager_program, "morez",
            "pager program should be picked up from PAGER when SQITCH_PAGER and core.pager are not set";
        isa_ok $sqitch->pager, $pager_class, 'morez pager';
    }

    {
        local $ENV{SQITCH_PAGER} = "less -myway";
        local $ENV{PAGER}        = "morezz";

        my $sqitch = App::Sqitch->new;
        is $sqitch->pager_program, "less -myway", "SQITCH_PAGER should take precedence over PAGER";
        isa_ok $sqitch->pager, $pager_class, 'less -myway';
    }

    {
        local $ENV{SQITCH_PAGER};
        local $ENV{PAGER}         = "morezz";

        my $config = TestConfig->from(local => 'sqitch.conf');
        my $sqitch = App::Sqitch->new(config => $config);
        is $sqitch->pager_program, "less -r",
            "`core.pager' setting should take precedence over PAGER when SQITCH_PAGER is not set.";
        isa_ok $sqitch->pager, $pager_class, 'morezz pager';
    }

    {
        local $ENV{SQITCH_PAGER}  = "less -rules";
        local $ENV{PAGER}         = "more -dontcare";

        # Should always get IO::Handle with --no-pager.
        my $config = TestConfig->from(local => 'sqitch.conf');
        my $sqitch = App::Sqitch->new(config => $config, options => {no_pager => 1});
        is $sqitch->pager_program, "less -rules",
            "SQITCH_PAGER should take precedence over both PAGER and the `core.pager' setting.";
        isa_ok $sqitch->pager, 'IO::Handle', 'less -rules';
    }
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

# Trace literal
$sqitch = $CLASS->new(verbosity => 3);
is capture_stdout { $sqitch->trace_literal('This ', "that\n", 'and the other') },
    "trace: This that\ntrace: and the other",
    'trace_literal should work';
$sqitch = $CLASS->new(verbosity => 2);
is capture_stdout { $sqitch->trace_literal('This ', "that\n", 'and the other') },
    '', 'Should get no trace_literal output for verbosity 2';

# Debug.
$sqitch = $CLASS->new(verbosity => 2);
is capture_stdout { $sqitch->debug('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other\n",
    'debug should work';
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->debug('This ', "that\n", 'and the other') },
    '', 'Should get no debug output for verbosity 1';

# Debug literal.
$sqitch = $CLASS->new(verbosity => 2);
is capture_stdout { $sqitch->debug_literal('This ', "that\n", 'and the other') },
    "debug: This that\ndebug: and the other",
    'debug_literal should work';
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->debug_literal('This ', "that\n", 'and the other') },
    '', 'Should get no debug_literal output for verbosity 1';

# Info.
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->info('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'info should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->info('This ', "that\n", 'and the other') },
    '', 'Should get no info output for verbosity 0';

# Info literal.
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->info_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'info_literal should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->info_literal('This ', "that\n", 'and the other') },
    '', 'Should get no info_literal output for verbosity 0';

# Comment.
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->comment('This ', "that\n", 'and the other') },
    "# This that\n# and the other\n",
    'comment should work with verbosity 0';

# Comment literal.
$sqitch = $CLASS->new(verbosity => 1);
is capture_stdout { $sqitch->comment_literal('This ', "that\n", 'and the other') },
    "# This that\n# and the other",
    'comment_literal should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->comment_literal('This ', "that\n", 'and the other') },
    "# This that\n# and the other",
    'comment_literal should work with verbosity 0';

# Emit.
is capture_stdout { $sqitch->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->emit('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'emit should work even with verbosity 0';

# Emit literal.
is capture_stdout { $sqitch->emit_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'emit_literal should work';
$sqitch = $CLASS->new(verbosity => 0);
is capture_stdout { $sqitch->emit_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'emit_literal should work even with verbosity 0';

# Warn.
is capture_stderr { $sqitch->warn('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other\n",
    'warn should work';

# Warn_Literal.
is capture_stderr { $sqitch->warn_literal('This ', "that\n", 'and the other') },
    "warning: This that\nwarning: and the other",
    'warn_literal should work';

# Vent.
is capture_stderr { $sqitch->vent('This ', "that\n", 'and the other') },
    "This that\nand the other\n",
    'vent should work';

# Vent literal.
is capture_stderr { $sqitch->vent_literal('This ', "that\n", 'and the other') },
    "This that\nand the other",
    'vent_literal should work';

##############################################################################
# Test run().
can_ok $CLASS, 'run';
my ($stdout, $stderr) = capture {
    ok $sqitch->run(
        $^X, 'echo.pl', qw(hi there)
    ), 'Should get success back from run echo';
};

is $stdout, "hi there\n", 'The echo script should have run';
is $stderr, '', 'Nothing should have gone to STDERR';

($stdout, $stderr) = capture {
    throws_ok {
        $sqitch->run( $^X, 'die.pl', qw(hi there))
    } qr/unexpectedly returned/, 'run die should, well, die';
};

is $stdout, "hi there\n", 'The die script should have its STDOUT ummolested';
like $stderr, qr/OMGWTF/, 'The die script should have its STDERR unmolested';

##############################################################################
# Test shell().
can_ok $CLASS, 'shell';
my $pl = $sqitch->quote_shell($^X);
($stdout, $stderr) = capture {
    ok $sqitch->shell(
        "$pl echo.pl hi there"
    ), 'Should get success back from shell echo';
};

is $stdout, "hi there\n", 'The echo script should have shell';
is $stderr, '', 'Nothing should have gone to STDERR';

($stdout, $stderr) = capture {
    throws_ok {
        $sqitch->shell( "$pl die.pl hi there" )
    } qr/unexpectedly returned/, 'shell die should, well, die';
};

is $stdout, "hi there\n", 'The die script should have its STDOUT ummolested';
like $stderr, qr/OMGWTF/, 'The die script should have its STDERR unmolested';

##############################################################################
# Test quote_shell().
my $quoter = do {
    if (App::Sqitch::ISWIN) {
        require Win32::ShellQuote;
         \&Win32::ShellQuote::quote_native;
    } else {
        require String::ShellQuote;
        \&String::ShellQuote::shell_quote;
    }
};

is $sqitch->quote_shell(qw(foo bar baz), 'hi there'),
    $quoter->(qw(foo bar baz), 'hi there'), 'quote_shell should work';

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
seek $fh, 0, 0;
open my $fh2, '<', \$CLASS;
is capture_stdout {
    ok $sqitch->spool([$fh, $fh2], $^X, 'read.pl'), 'Spool to read.pl';
}, $data . $CLASS, 'All data should have been sent to STDOUT by read.pl';

like capture_stderr {
    local $ENV{LANGUAGE} = 'en';
    throws_ok { $sqitch->spool($fh, $^X, 'die.pl') }
        'App::Sqitch::X', 'Should get error when die.pl dies';
    is $@->ident, 'io', 'Error ident should be "io"';
    like $@->message,
        qr/\Q$^X\E unexpectedly returned exit value |\QError closing pipe to/,
        'The error message should be one of the I/O messages';
}, qr/OMGWTF/, 'The die script STDERR should have passed through';

throws_ok {
    local $ENV{LANGUAGE} = 'en';
    $sqitch->spool($fh, '--nosuchscript.ply--')
} 'App::Sqitch::X', 'Should get an error for a bad command';
is $@->ident, 'io', 'Error ident should be "io"';
like $@->message,
    qr/\QCannot exec --nosuchscript.ply--:\E|\QError closing pipe to --nosuchscript.ply--:/,
    'Error message should be about inability to exec';

##############################################################################
# Test prompt().
throws_ok { $sqitch->prompt } 'App::Sqitch::X',
    'Should get error for no prompt message';
is $@->ident, 'DEV', 'No prompt ident should be "DEV"';
is $@->message, 'prompt() called without a prompt message',
    'No prompt error message should be correct';

my $sqitch_mock = Test::MockModule->new($CLASS);
my $input = 'hey';
$sqitch_mock->mock(_readline => sub { $input });
my $unattended = 0;
$sqitch_mock->mock(_is_unattended => sub { $unattended });

is capture_stdout {
    is $sqitch->prompt('hi'), 'hey', 'Prompt should return input';
}, 'hi ', 'Prompt should prompt';

$input = 'how';
is capture_stdout {
    is $sqitch->prompt('hi', 'blah'), 'how',
        'Prompt with default should return input';
}, 'hi [blah] ', 'Prompt should prompt with default';
$input = 'hi';
is capture_stdout {
    is $sqitch->prompt('hi', undef), 'hi',
        'Prompt with undef default should return input';
}, 'hi [] ', 'Prompt should prompt with bracket for undef default';

$input = undef;
is capture_stdout {
    is $sqitch->prompt('hi', 'yo'), 'yo',
        'Prompt should return default for undef input';
}, 'hi [yo] ', 'Prompt should show default when undef input';

$input = '';
is capture_stdout {
    is $sqitch->prompt('hi', 'yo'), 'yo',
        'Prompt should return input for empty input';
}, 'hi [yo] ', 'Prompt should show default when empty input';

$unattended = 1;
throws_ok {
    is capture_stdout { $sqitch->prompt('yo') }, "yo   \n",
        'Unattended message should be emitted';
} 'App::Sqitch::X', 'Should get error when uattended and no default';
is $@->ident, 'io', 'Unattended error ident should be "io"';
is $@->message, __(
    'Sqitch seems to be unattended and there is no default value for this question'
), 'Unattended error message should be correct';

is capture_stdout {
    is $sqitch->prompt('hi', 'yo'), 'yo', 'Prompt should return input';
}, "hi [yo] yo\n", 'Prompt should show default as selected when unattended';

##############################################################################
# Test ask_yes_no().
throws_ok { $sqitch->ask_yes_no } 'App::Sqitch::X',
    'Should get error for no ask_yes_no message';
is $@->ident, 'DEV', 'No ask_yes_no ident should be "DEV"';
is $@->message, 'ask_yes_no() called without a prompt message',
    'No ask_yes_no error message should be correct';

my $yes = __ 'Yes';
my $no = __ 'No';

# Test affermation.
for my $variant ($yes, lc $yes, uc $yes, lc substr($yes, 0, 1), substr($yes, 0, 2)) {
    $input = $variant;
    $unattended = 0;
    is capture_stdout {
        ok $sqitch->ask_yes_no('hi'),
            qq{ask_yes_no() should return true for "$variant" input};
    }, 'hi ', qq{ask_yes_no() should prompt for "$variant"};
}

# Test negation.
for my $variant ($no, lc $no, uc $no, lc substr($no, 0, 1), substr($no, 0, 2)) {
    $input = $variant;
    $unattended = 0;
    is capture_stdout {
        ok !$sqitch->ask_yes_no('hi'),
            qq{ask_yes_no() should return false for "$variant" input};
    }, 'hi ', qq{ask_yes_no() should prompt for "$variant"};
}

# Test defaults.
$input = '';
is capture_stdout {
    ok $sqitch->ask_yes_no('whu?', 1),
        'ask_yes_no() should return true for true default'
}, "whu? [$yes] ", 'ask_yes_no() should prompt and show default "Yes"';
is capture_stdout {
    ok !$sqitch->ask_yes_no('whu?', 0),
        'ask_yes_no() should return false for false default'
}, "whu? [$no] ", 'ask_yes_no() should prompt and show default "No"';

my $please = __ 'Please answer "y" or "n".';
$input = 'ha!';
throws_ok {
    is capture_stdout { $sqitch->ask_yes_no('hi')  },
        "hi  \n$please\nhi  \n$please\nhi  \n",
         'Should get prompts for repeated bad answers';
} 'App::Sqitch::X', 'Should get error for bad answers';
is $@->ident, 'io', 'Bad answers ident should be "IO"';
is $@->message, __ 'No valid answer after 3 attempts; aborting',
    'Bad answers message should be correct';

##############################################################################
# Test ask_y_n().
my $warning;
$sqitch_mock->mock(warn => sub { shift; $warning = "@_" });
throws_ok { $sqitch->ask_y_n } 'App::Sqitch::X',
    'Should get error for no ask_y_n message';
is $@->ident, 'DEV', 'No ask_y_n ident should be "DEV"';
is $@->message, 'ask_yes_no() called without a prompt message',
    'No ask_y_n error message should be correct';
is $warning, 'The ask_y_n() method has been deprecated. Use ask_yes_no() instead.',
    'Should get a deprecation warning from ask_y_n';

throws_ok { $sqitch->ask_y_n('hi', 'b') } 'App::Sqitch::X',
    'Should get error for invalid ask_y_n default';
is $@->ident, 'DEV', 'Invalid ask_y_n default ident should be "DEV"';
is $@->message, 'Invalid default value: ask_y_n() default must be "y" or "n"',
    'Invalid ask_y_n default error message should be correct';

$input = lc substr $yes, 0, 1;
$unattended = 0;
is capture_stdout {
    ok $sqitch->ask_y_n('hi'),
        qq{ask_y_n should return true for "$input" input}
}, 'hi ', 'ask_y_n() should prompt';

$input = lc substr $no, 0, 1;
is capture_stdout {
    ok !$sqitch->ask_y_n('howdy'),
        qq{ask_y_n should return false for "$input" input}
}, 'howdy ', 'ask_y_n() should prompt for no';

$input = uc substr $no, 0, 1;
is capture_stdout {
    ok !$sqitch->ask_y_n('howdy'),
        qq{ask_y_n should return false for "$input" input}
}, 'howdy ', 'ask_y_n() should prompt for no';

$input = uc substr $yes, 0, 2;
is capture_stdout {
    ok $sqitch->ask_y_n('howdy'),
        qq{ask_y_n should return true for "$input" input}
}, 'howdy ', 'ask_y_n() should prompt for yes';

$input = '';
is capture_stdout {
    ok $sqitch->ask_y_n('whu?', 'y'),
        qq{ask_y_n should return true default "$yes"}
}, "whu? [$yes] ", 'ask_y_n() should prompt and show default "Yes"';

is capture_stdout {
    ok !$sqitch->ask_y_n('whu?', 'n'),
        qq{ask_y_n should return false default "$no"};
}, "whu? [$no] ", 'ask_y_n() should prompt and show default "No"';

$input = 'ha!';
throws_ok {
    is capture_stdout { $sqitch->ask_y_n('hi')  },
        "hi  \n$please\nhi  \n$please\nhi  \n",
         'Should get prompts for repeated bad answers';
} 'App::Sqitch::X', 'Should get error for bad answers';
is $@->ident, 'io', 'Bad answers ident should be "IO"';
is $@->message, __ 'No valid answer after 3 attempts; aborting',
    'Bad answers message should be correct';

##############################################################################
# Test _readline.
$sqitch_mock->unmock('_readline');
$input = 'hep';
open my $stdin, '<', \$input;
*STDIN = $stdin;
is $sqitch->_readline, $input, '_readline should work';

$unattended = 1;
is $sqitch->_readline, undef, '_readline should return undef when unattended';
$sqitch_mock->unmock_all;

##############################################################################
# Make sure Test::LocaleDomain gives us decoded strings.
for my $lang (qw(en fr)) {
    local $ENV{LANGUAGE} = $lang;
    my $text = __x 'On database {db}', db => 'foo';
    ok utf8::valid($text), 'Localied string should be valid UTF-8';
    ok utf8::is_utf8($text), 'Localied string should be decoded';
}
