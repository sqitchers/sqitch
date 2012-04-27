#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 33;
#use Test::More 'no_plan';
use Test::MockModule;
use Path::Class;

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
    is $sqitch->db_name, 'widgetopolis', 'db_name should be set by config';
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
