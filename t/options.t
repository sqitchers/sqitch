#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 9;
#use Test::More 'no_plan';
use Test::MockModule;
use Capture::Tiny ':all';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

is_deeply [ $CLASS->_split_opts('help') ], [[], 'help', []],
    'Split on command-only';

is_deeply [ $CLASS->_split_opts('--help', 'help') ], [
    ['--help'],
    'help',
    [],
], 'Split on core option plus command';

is_deeply [ $CLASS->_split_opts('--help', 'help', '--foo') ], [
    ['--help'],
    'help',
    ['--foo'],
], 'Split on core option plus command plus command option';

is_deeply [ $CLASS->_split_opts('--plan-file', 'foo', 'help', '--foo') ], [
    ['--plan-file', 'foo'],
    'help',
    ['--foo'],
], 'Option with arg should work';

is_deeply [$CLASS->_split_opts(qw(
    --plan-file
    foo
    help
    --foo
))], [
    ['--plan-file', 'foo'],
    'help',
    ['--foo'],
], 'Option with arg should work';

is_deeply [ $CLASS->_split_opts('--help') ], [['--help'], undef, []],
    'Should handle no command';

# Make sure an invalid option is caught.
my $mocker = Test::MockModule->new($CLASS);
$mocker->mock(_pod2usage => sub {  pass '_pod2usage should be called' });

is capture_stderr { $CLASS->_split_opts('--foo', 'foo', 'help', '--bar') },
    "Unknown option: foo\n", 'Should exit for invalid option';
