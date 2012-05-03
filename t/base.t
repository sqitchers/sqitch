#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 64;
#use Test::More 'no_plan';
use Test::MockModule;
use Path::Class;
use Test::Exception;
use Capture::Tiny ':all';

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
    engine
    _engine
    client
    db_name
    username
    host
    port
    sql_dir
    deploy_dir
    revert_dir
    test_dir
    extension
    dry_run
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

is $sqitch->plan_file, file('sqitch.plan'), 'Default plan file should be sqitch.plan';
is $sqitch->verbosity, 1, 'verbosity should be 1';
is $sqitch->dry_run, 0, 'dry_run should be 0';
is $sqitch->extension, 'sql', 'Default extension should be sql';
is $sqitch->sql_dir, dir('sql'), 'Default sql_dir should be ./sql';
is $sqitch->deploy_dir, dir(qw(sql deploy)), 'Default deploy_dir should be ./sql/deploy';
is $sqitch->revert_dir, dir(qw(sql revert)), 'Default revert_dir should be ./sql/revert';
is $sqitch->test_dir, dir(qw(sql test)), 'Default test_dir should be ./sql/test';

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

# Fail.
is capture_stderr {
    throws_ok { $sqitch->fail('This ', "that\n", "and the other") }
        qr/EXITED: 2/
}, "fatal: This that\nfatal: and the other\n",
    'fail should work';

# Unfound
is capture_stderr {
    throws_ok { $sqitch->unfound } qr/EXITED: 1/
}, '', 'unfound print nothing';

# Help.
$0 = 'sqch';
is capture_stderr {
    throws_ok { $sqitch->help('This ', "that\n", "and the other.") }
        qr/EXITED: 1/
}, "sqch: This that\nsqch: and the other. See sqch --help\n",
    'help should work';

is capture_stderr {
    throws_ok { $sqitch->help('This ', "that\n", "and the other.") }
        qr/EXITED: 1/
}, "sqch: This that\nsqch: and the other. See sqch --help\n",
    'help should work';

# Bail.
is capture_stdout {
    throws_ok { $sqitch->bail(0, 'This ', "that\n", "and the other") }
        qr/EXITED: 0/
}, "This that\nand the other\n",
    'bail should work with exit code 0';

is capture_stdout {
    throws_ok { $sqitch->bail(0) } qr/EXITED: 0/
}, '',  'bail 0 should emit nothing when no messages';

is capture_stderr {
    throws_ok { $sqitch->bail(1, 'This ', "that\n", "and the other") }
        qr/EXITED: 1/
}, "This that\nand the other\n",
    'bail should work with exit code 1';

is capture_stderr {
    throws_ok { $sqitch->bail(2) } qr/EXITED: 2/
}, '',  'bail 2 should emit nothing when no messages';

##############################################################################
# Test do_system().
can_ok $CLASS, 'do_system';
is capture_stdout {
    ok $sqitch->do_system(
        $^X, 'echo.pl', qw(hi there)
    ), 'Should get success back from do_system echo';
}, "hi there\n", 'The echo script should have run';

is capture_stdout {
    ok !$sqitch->do_system(
        $^X, 'die.pl', qw(hi there)
    ), 'Should get fail back from do_system die';
}, "hi there\n", 'The die script should have run';

