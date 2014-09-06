#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 242;
#use Test::More 'no_plan';
use Test::MockModule;
use Path::Class;
use Test::Exception;
use Test::NoWarnings;
use Capture::Tiny 0.12 qw(:all);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X 'hurl';

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

$ENV{SQITCH_CONFIG} = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG} = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

can_ok $CLASS, qw(
    go
    new
    plan_file
    plan
    engine
    _engine
    user_name
    user_email
    db_client
    db_name
    db_username
    db_host
    db_port
    top_dir
    deploy_dir
    revert_dir
    verify_dir
    extension
    verbosity
    prompt
    ask_y_n
);

##############################################################################
# Defaults.
isa_ok my $sqitch = $CLASS->new, $CLASS, 'A new object';

for my $attr (qw(
    db_client
    db_username
    db_name
    db_host
    db_port
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
is $sqitch->verify_dir, dir(qw(verify)), 'Default verify_dir should be ./sql/verify';
isa_ok $sqitch->plan, 'App::Sqitch::Plan';
ok $sqitch->user_name, 'Default user_name should be set from system';
is $sqitch->user_email, do {
    require Sys::Hostname;
    $sqitch->sysuser . '@' . Sys::Hostname::hostname();
}, 'Default user_email should be set from system';

# Test engine_key.
throws_ok { $sqitch->engine_key } 'App::Sqitch::X',
    'Should get exception for no engine_key';
is $@->ident, 'core', 'No engine_key error ident should be "core"';
is $@->message, __ 'No engine specified; use --engine or set core.engine',
    'No engine_key error message should be correct';
throws_ok { $sqitch->engine } 'App::Sqitch::X',
    'Should get exception for no engine';
is $@->ident, 'core', 'No engine error ident should be "core"';
is $@->message, __ 'No engine specified; use --engine or set core.engine',
    'No engine error message should be correct';

# Try an unknown engine.
throws_ok { $CLASS->new(_engine => 'nonexistent')->engine_key } 'App::Sqitch::X',
    'Should get error for unknown engine';
is $@->ident, 'core', 'Unknown engine error ident should be "core"';
is $@->message, __x('Unknown engine "{engine}"', engine => 'nonexistent'),
    'Unknown engine error message should be correct';

# Try engine key from URI.
is $sqitch->engine_key(URI->new('db:sqlite:foo')), 'sqlite',
    'Should derive sqlite engine key from URI';

# Try a URI with a driver that is not lowercase.
is $sqitch->engine_key(URI->new('db:pg:foo')), 'pg',
    'Should derive pg engine key from URI';

throws_ok { $sqitch->engine_key(URI->new('db:nonexistent:')) } 'App::Sqitch::X',
    'Should get error for nonexistent engine';
is $@->ident, 'core', 'Nonexistent engine error ident should be "core"';
is $@->message, __x('Unknown engine "{engine}"', engine => 'nonexistent'),
    'Nonexistent engine error message should be correct';

throws_ok { $sqitch->engine_key(URI->new('file:foo:')) } 'App::Sqitch::X',
    'Should get error for non-db URI';
is $@->ident, 'core', 'Non-db URI error ident should be "core"';
is $@->message,  __x(
    'URI "{uri}" is not a database URI',
    uri => 'file:foo:'
), 'Non-DB URI error message should be correct';

# Valid engines and the engine constructors.
for my $eng (qw(pg sqlite mysql oracle firebird vertica)) {
    ok my $sqitch = $CLASS->new(engine_key => $eng),
        qq{Engine "$eng" should be valid};

    my $uri = URI->new("db:$eng:foo");
    isa_ok my $engine = $sqitch->engine( uri => $uri ),
        "App::Sqitch::Engine::$eng", "$eng engine";
    is $engine->uri, $uri, "URI $uri should have been passed through";

    ok $engine = $sqitch->engine({ uri => $uri }),
        "Create another App::Sqitch::Engine::$eng with hash params";
    is $engine->uri, $uri, "URI $uri should have been passed through again";
}

##############################################################################
# Test config_for_target.
is $sqitch->config_for_target, undef, 'Should get no string for no DB param';
is $sqitch->config_for_target(undef), undef, 'Should get no string for undef DB param';
is $sqitch->config_for_target(''), undef, 'Should get no string for empty DB param';
is $sqitch->config_for_target(0), undef, 'Should get no string for DB param 0';

# Pass a URI.
is_deeply $sqitch->config_for_target('db:pg:'), {
    target => 'db:pg:',
    uri     => URI->new('db:pg:'),
}, 'Should get target back from config_for_target()';

# Pass a key.
CONFIG: {
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my @params;
    my $ret = { uri => URI->new('db:sqlite:hi') };
    $mock->mock(get_section => sub { shift; @params = @_; $ret });
    is_deeply $sqitch->config_for_target('grokker'), $ret,
        'Should get target for URI key';
    is_deeply \@params, [section => 'target.grokker'],
        'The URI should have been fetched from the config';
    $ret = undef;
    is $sqitch->config_for_target('whatever'), undef,
        'Should get back undef when no URI for key';
    is_deeply \@params, [section => 'target.whatever'],
        'The URI should have been sought in the config';
}

##############################################################################
# Test config_for_target_strict.
is_deeply $sqitch->config_for_target_strict('db:pg:foo'), {
    target => 'db:pg:foo',
    uri    => URI->new('db:pg:foo'),
}, 'Should get URI back for URI param';
isa_ok $sqitch->config_for_target_strict('db:pg:foo')->{uri}, 'URI::db', 'DB URI';

# Pass a key.
CONFIG: {
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my @params;
    my $ret = { uri => URI->new('db:sqlite:hi') };
    $mock->mock(get_section => sub { shift; @params = @_; $ret });
    is_deeply $sqitch->config_for_target_strict('grokker'), $ret,
        'Should get target back for URI key';
    is_deeply \@params, [section => 'target.grokker'],
        'The target should have been fetched from the config';
    isa_ok $sqitch->config_for_target_strict('bob')->{uri}, 'URI::db',
        'DB URI from config';
    is_deeply \@params, [section => 'target.bob'],
        'The new URI should have been fetched from the config';
    $ret = undef;
    throws_ok { $sqitch->config_for_target_strict('grokker') } 'App::Sqitch::X',
        'Should get an exception for unknown config DB key';
    is $@->ident, 'core', 'Unknown key error ident should be "core"';
    is $@->message, __x(
        'Cannot find target "{target}"',
        target => 'grokker'
    ), 'The unknown key error message should be correct';
}

##############################################################################
# Test engine_for_target.
$sqitch = $CLASS->new( _engine => 'sqlite' );
my $def_uri = $sqitch->engine->uri;
isa_ok $sqitch->engine_for_target, 'App::Sqitch::Engine', 'Engine for DB';
is $sqitch->engine_for_target->uri,        $def_uri, 'Should get default engine for no DB param';
is $sqitch->engine_for_target(undef)->uri, $def_uri, 'Should get default engine for undef DB param';
is $sqitch->engine_for_target('')->uri,    $def_uri, 'Should get default engine for empty DB param';
is $sqitch->engine_for_target(0)->uri,     $def_uri, 'Should get default engine for DB param 0';
is $sqitch->engine_for_target->target,     $def_uri, 'Should get default engine target';

# Pass a URI.
isa_ok my $engine = $sqitch->engine_for_target('db:pg:foo'),
    'App::Sqitch::Engine';
is $engine->uri, URI->new('db:pg:foo'),
    'Should get properly configured engine URI';
is $engine->uri, 'db:pg:foo', 'Should get properly-configured target for URI';

# Pass a key.
CONFIG: {
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my $ret = { uri => URI->new('db:sqlite:hi') };
    $mock->mock(get_section => sub { $ret });
    is_deeply $sqitch->engine_for_target('grokker')->uri, 'db:sqlite:hi',
        'Should get engine with URI for URI key';
    isa_ok my $engine = $sqitch->engine_for_target('bob'), 'App::Sqitch::Engine',
        'Engine with URI from config';
    is $engine->target, 'bob', 'Engine should know target as "bob"';
    is $engine->uri, URI->new('db:sqlite:hi'), 'Engine should have bob URI';

    # Should also work when specifying a URI.
    isa_ok $engine = $sqitch->engine_for_target('db:sqlite:fred'), 'App::Sqitch::Engine',
        'Engine with URI param';
    is $engine->target, 'db:sqlite:fred', 'Engine should know target by URI';
    is $engine->uri, URI->new('db:sqlite:fred'), 'Engine should have URI';

    # Now set a default target.
    $mock->mock(get => 'bob');
    isa_ok $engine = $sqitch->engine_for_target('db:sqlite:fred'), 'App::Sqitch::Engine',
        'Engine with URI param';
    is $engine->target, 'db:sqlite:fred', 'Engine should know target by URI';
    is $engine->uri, URI->new('db:sqlite:fred'), 'Engine should have URI';

    $ret = undef;
    throws_ok { $sqitch->engine_for_target('grokker') } 'App::Sqitch::X',
        'Should get an exception for unknown config DB key';
    is $@->ident, 'core', 'Unknown key error ident should be "core"';
    is $@->message, __x(
        'Cannot find target "{key}"',
        key => 'grokker'
    ), 'The unknown key error message should be correct';
}

# Test invalid user name and email values.
throws_ok { $CLASS->new(user_name => 'foo<bar') } 'App::Sqitch::X',
    'Should get error for user name containing "<"';
is $@->ident, 'user', 'Invalid user name error ident should be "user"';
is $@->message, __ 'User name may not contain "<" or start with "["',
    'Invalid user name error message should be correct';

throws_ok { $CLASS->new(user_name => '[foobar]') } 'App::Sqitch::X',
    'Should get error for user name starting with "["';
is $@->ident, 'user', 'Second Invalid user name error ident should be "user"';
is $@->message, __ 'User name may not contain "<" or start with "["',
    'Second Invalid user name error message should be correct';

throws_ok { $CLASS->new(user_email => 'foo>bar') } 'App::Sqitch::X',
    'Should get error for user email containing ">"';
is $@->ident, 'user', 'Invalid user email error ident should be "user"';
is $@->message, __ 'User email may not contain ">"',
    'Invalid user email error message should be correct';

##############################################################################
# Test go().
GO: {
    my $mock = Test::MockModule->new('App::Sqitch::Command::help');
    my ($cmd, @params);
    my $ret = 1;
    $mock->mock(execute => sub { ($cmd, @params) = @_; $ret });
    chdir 't';
    local $ENV{SQITCH_CONFIG} = 'sqitch.conf';
    local $ENV{SQITCH_USER_CONFIG} = 'user.conf';
    local @ARGV = qw(--engine sqlite help config);
    is +App::Sqitch->go, 0, 'Should get 0 from go()';

    isa_ok $cmd, 'App::Sqitch::Command::help', 'Command';
    is_deeply \@params, ['config'], 'Extra args should be passed to execute';

    isa_ok my $sqitch = $cmd->sqitch, 'App::Sqitch';
    is $sqitch->engine_key, 'sqlite', 'Engine should be set by option';
    # isa $sqitch->engine, 'App::Sqitch::Engine::sqlite',
    #     'Engine object should be constructable';
    is $sqitch->extension, 'ddl', 'ddl should be set by config';
    ok my $config = $sqitch->config, 'Get the Sqitch config';
    is $config->get(key => 'core.pg.client'), '/usr/local/pgsql/bin/psql',
        'Should have local config overriding user';
    is $config->get(key => 'core.pg.host'), 'localhost',
        'Should fall back on user config';
    is $sqitch->user_name, 'Michael Stonebraker',
        'Should have read user name from configuration';
    is $sqitch->user_email, 'michael@example.com',
        'Should have read user email from configuration';

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
    if ($^O eq 'MSWin32') {
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
# Test ask_y_n().
throws_ok { $sqitch->ask_y_n } 'App::Sqitch::X',
    'Should get error for no ask_y_n message';
is $@->ident, 'DEV', 'No ask_y_n ident should be "DEV"';
is $@->message, 'ask_y_n() called without a prompt message',
    'No ask_y_n error message should be correct';

throws_ok { $sqitch->ask_y_n('hi', 'b') } 'App::Sqitch::X',
    'Should get error for invalid ask_y_n default';
is $@->ident, 'DEV', 'Invalid ask_y_n default ident should be "DEV"';
is $@->message, 'Invalid default value: ask_y_n() default must be "y" or "n"',
    'Invalid ask_y_n default error message should be correct';

$input = 'y';
$unattended = 0;
is capture_stdout {
    ok $sqitch->ask_y_n('hi'), 'ask_y_n should return true for "y" input';
}, 'hi ', 'ask_y_n() should prompt';

$input = 'no';
is capture_stdout {
    ok !$sqitch->ask_y_n('howdy'), 'ask_y_n should return false for "no" input';
}, 'howdy ', 'ask_y_n() should prompt for no';

$input = 'Nein';
is capture_stdout {
    ok !$sqitch->ask_y_n('howdy'), 'ask_y_n should return false for "Nein"';
}, 'howdy ', 'ask_y_n() should prompt for no';

$input = 'Yep';
is capture_stdout {
    ok $sqitch->ask_y_n('howdy'), 'ask_y_n should return true for "Yep"';
}, 'howdy ', 'ask_y_n() should prompt for yes';

$input = '';
is capture_stdout {
    ok $sqitch->ask_y_n('whu?', 'y'), 'ask_y_n should return true default "y"';
}, 'whu? [y] ', 'ask_y_n() should prompt and show default "y"';
is capture_stdout {
    ok !$sqitch->ask_y_n('whu?', 'n'), 'ask_y_n should return false default "n"';
}, 'whu? [n] ', 'ask_y_n() should prompt and show default "n"';

my $please = __ 'Please answer "y" or "n".';
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
