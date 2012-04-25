#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
use Test::More tests => 21;
#use Test::More 'no_plan';
use App::Sqitch;
use Path::Class;
use Test::Dir;
use Test::Exception;
use File::Path qw(remove_tree make_path);
use lib 't/lib';
use MockCommand;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command::init';
    use_ok $CLASS or die;
}

isa_ok $CLASS, 'App::Sqitch::Command', $CLASS;
my $sqitch = App::Sqitch->new(sql_dir => dir 'init.sql');
isa_ok my $init = $CLASS->new(sqitch => $sqitch), $CLASS, 'New init object';

##############################################################################
# Test make_directories.
chdir 't';
can_ok $init, 'make_directories';
for my $attr (map { "$_\_dir"} qw(sql deploy revert test)) {
    dir_not_exists_ok $sqitch->$attr;
}

END { remove_tree $sqitch->sql_dir->stringify }

ok $init->make_directories, 'Make the directories';
for my $attr (map { "$_\_dir"} qw(sql deploy revert test)) {
    dir_exists_ok $sqitch->$attr;
}
is_deeply +MockCommand->get_info, [
    map { ["Created " . $sqitch->$_] } map { "$_\_dir" } qw(deploy revert test)
], 'Each should have been sent to info';

# Do it again.
ok $init->make_directories, 'Make the directories again';
is_deeply +MockCommand->get_info, [], 'Nothing should have been sent to info';

# Delete one of them.
remove_tree $sqitch->revert_dir->stringify;
ok $init->make_directories, 'Make the directories once more';
dir_exists_ok $sqitch->revert_dir, 'revert dir exists again';
is_deeply +MockCommand->get_info, [
    ['Created ' . $sqitch->revert_dir],
], 'Should have noted creation of revert dir';

# Handle errors.
my $sql_dir = $sqitch->sql_dir->stringify;
remove_tree $sql_dir;
make_path $sql_dir;
chmod 0000, $sql_dir;
END { chmod 0400, $sql_dir }
throws_ok { $init->make_directories } qr/FAIL/, 'Should fail on permissio issue';
is_deeply +MockCommand->get_fail, [
    ['Error creating ' . $sqitch->deploy_dir . ': Permission denied'],
], 'Failure should have been emitted';
