#!/usr/bin/perl -w

use strict;
use warnings;
use v5.10;
use utf8;
use Test::More tests => 25;
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
chdir 't';


sub read_config($) {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}

##############################################################################
# Test make_directories.
my $sqitch = App::Sqitch->new(sql_dir => dir 'init.mkdir');
isa_ok my $init = $CLASS->new(sqitch => $sqitch), $CLASS, 'New init object';

can_ok $init, 'make_directories';
for my $attr (map { "$_\_dir"} qw(sql deploy revert test)) {
    dir_not_exists_ok $sqitch->$attr;
}

my $sql_dir = $sqitch->sql_dir->stringify;
END { remove_tree $sql_dir }

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
remove_tree $sql_dir;
make_path $sql_dir;
chmod 0000, $sql_dir;
END { chmod 0400, $sql_dir }
throws_ok { $init->make_directories } qr/FAIL/, 'Should fail on permissio issue';
is_deeply +MockCommand->get_fail, [
    ['Error creating ' . $sqitch->deploy_dir . ': Permission denied'],
], 'Failure should have been emitted';

##############################################################################
# Test write_config().
can_ok $init, 'write_config';

my $test_dir = 'init.write';
make_path $test_dir;
END { remove_tree $test_dir }
chdir $test_dir;
END { chdir File::Spec->updir }

# Write config.
ok $init->write_config, 'Write the config';
is_deeply read_config $sqitch->config->project_file, {
    'core.sql_dir' => 'init.mkdir',
}, 'The configuration should have been written with only one setting';
is_deeply +MockCommand->get_info, [
    ['Created ' . $sqitch->config->project_file]
], 'The creation should be sent to info';

