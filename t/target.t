#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 142;
use Test::More 'no_plan';
use App::Sqitch;
use Path::Class qw(dir);

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::Target';
    use_ok $CLASS or die;
}

##############################################################################
# Load a target and test the basics.
ok my $sqitch = App::Sqitch->new(options => { engine => 'sqlite'}),
    'Load a sqitch sqitch object';
isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS;
can_ok $target, qw(
    new
    name
    uri
    sqitch
    engine
    registry
    client
    plan_file
    plan
    top_dir
    deploy_dir
    revert_dir
    verify_dir
    extension
);

# Look at default values.
is $target->name, 'db:sqlite:', 'Name should be "db:sqlite"';
is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite"';
is $target->sqitch, $sqitch, 'Sqitch should be as passed';
isa_ok $target->engine, 'App::Sqitch::Engine::sqlite', 'Engine';
is $target->registry, $target->engine->default_registry,
    'Should have default registry';
is $target->client, $target->engine->default_client,
    'Should have default client';
is $target->top_dir, dir, 'Should have default top_dir';
is $target->deploy_dir, $target->top_dir->subdir('deploy'),
    'Should have default deploy_dir';
is $target->revert_dir, $target->top_dir->subdir('revert'),
    'Should have default revert_dir';
is $target->verify_dir, $target->top_dir->subdir('verify'),
    'Should have default verify_dir';
is $target->extension, 'sql', 'Should have default extension';
is $target->plan_file, $target->top_dir->file('sqitch.plan')->cleanup,
    'Should have default plan file';
isa_ok $target->plan, 'App::Sqitch::Plan', 'Should get plan';
