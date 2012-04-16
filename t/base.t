#!/usr/bin/perl -w

use strict;
use warnings;
#use Test::More tests => 1;
use Test::More 'no_plan';

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

