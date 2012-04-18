#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 24;
#use Test::More 'no_plan';
use Test::MockModule;

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
    plan_file
    engine
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
)) {
    is $sqitch->$attr, undef, "$attr should be undef";
}

# is $sqitch->username, $ENV{USER}, 'Default user should be $ENV{USER}';
# is $sqitch->db_name, $sqitch->username, 'Default DB should be same as user';
is $sqitch->verbosity, 0, 'verbosity should be 0';

##############################################################################
# Test go().
GO: {
    my $mock = Test::MockModule->new('App::Sqitch::Command::help');
    my ($cmd, @params);
    my $ret = 1;
    $mock->mock(execute => sub { ($cmd, @params) = @_; $ret });
    chdir 't';
    local @ARGV = qw(--engine sqlite help config);
    is +App::Sqitch->go, 0, 'Should get 0 from go()';

    isa_ok $cmd, 'App::Sqitch::Command::help', 'Command';
    is_deeply \@params, ['config'], 'Extra args should be passed to execute';

    isa_ok my $sqitch = $cmd->sqitch, 'App::Sqitch';
    is $sqitch->engine, 'sqlite', 'Engine should be set by option';
    is $sqitch->db_name, 'widgetopolis', 'db_name should be set by config';
    is $sqitch->extension, 'ddl', 'ddl should be set by config';
}
