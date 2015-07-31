#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 30;
#use Test::More 'no_plan';
use Test::MockModule;
use Capture::Tiny 0.12 ':all';

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

##############################################################################
# Test _split_args.
can_ok $CLASS, '_split_args';

is_deeply [ $CLASS->_split_args('help') ], [[], 'help', []],
    'Split on command-only';

is_deeply [ $CLASS->_split_args('--help', 'help') ], [
    ['--help'],
    'help',
    [],
], 'Split on core option plus command';

is_deeply [ $CLASS->_split_args('--help', 'help', '--foo') ], [
    ['--help'],
    'help',
    ['--foo'],
], 'Split on core option plus command plus command option';

is_deeply [ $CLASS->_split_args('--plan-file', 'foo', 'help', '--foo') ], [
    ['--plan-file', 'foo'],
    'help',
    ['--foo'],
], 'Option with arg should work';

is_deeply [$CLASS->_split_args(qw(
    --plan-file
    foo
    help
    --foo
))], [
    ['--plan-file', 'foo'],
    'help',
    ['--foo'],
], 'Option with arg should work';

is_deeply [ $CLASS->_split_args('--help') ], [['--help'], undef, []],
    'Should handle no command';

is_deeply [ $CLASS->_split_args('-vvv', 'deploy') ],
    [['-vvv'], 'deploy', []],
    'Spliting args when using bundling should work';

# Make sure an invalid option is caught.
INVALID: {
    my $mocker = Test::MockModule->new($CLASS);
    $mocker->mock(_pod2usage => sub {  pass '_pod2usage should be called' });
    is capture_stderr { $CLASS->_split_args('--foo', 'foo', 'help', '--bar') },
        "Unknown option: foo\n", 'Should exit for invalid option';
}

##############################################################################
# Test _parse_core_opts
can_ok $CLASS, '_parse_core_opts';

is_deeply $CLASS->_parse_core_opts([]), {},
    'Should have default config for no options';

# Make sure we can get help.
HELP: {
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(_pod2usage => sub { @args = @_} );
    ok $CLASS->_parse_core_opts(['--help']), 'Ask for help';
    is_deeply \@args, [ $CLASS, 'sqitchcommands', '-exitval', 0, '-verbose', 2 ],
        'Should have been helped';
    ok $CLASS->_parse_core_opts(['--man']), 'Ask for man';
    is_deeply \@args, [ $CLASS, 'sqitch', '-exitval', 0, '-verbose', 2 ],
        'Should have been manned';
}

##############################################################################
# Try lots of options.
my $opts = $CLASS->_parse_core_opts([
    '--plan-file'           => 'plan.txt',
    '--engine'              => 'pg',
    '--registry'            => 'reg',
    '--client'              => 'psql',
    '--db-name'             => 'try',
    '--db-user'             => 'bob',
    '--db-host'             => 'local',
    '--db-port'             => 2020,
    '--top-dir'             => 'ddl',
    '--deploy-dir'          => 'dep',
    '--revert-dir'          => 'rev',
    '--verify-dir'          => 'tst',
    '--reworked-dir'        => 'wrk',
    '--reworked-deploy-dir' => 'rdep',
    '--reworked-revert-dir' => 'rrev',
    '--reworked-verify-dir' => 'rtst',
    '--extension'           => 'ext',
    '--verbose', '--verbose',
]);

is_deeply $opts, {
    plan_file           => 'plan.txt',
    engine              => 'pg',
    registry            => 'reg',
    client              => 'psql',
    db_name             => 'try',
    db_username         => 'bob',
    db_host             => 'local',
    db_port             => 2020,
    top_dir             => 'ddl',
    deploy_dir          => 'dep',
    revert_dir          => 'rev',
    verify_dir          => 'tst',
    reworked_dir        => 'wrk',
    reworked_deploy_dir => 'rdep',
    reworked_revert_dir => 'rrev',
    reworked_verify_dir => 'rtst',
    extension           => 'ext',
    verbosity           => 2,
}, 'Should parse lots of options';

for my $dir (qw(
    top_dir
    deploy_dir
    revert_dir
    verify_dir
    reworked_dir
    reworked_deploy_dir
    reworked_revert_dir
    reworked_verify_dir
)) {
    isa_ok $opts->{$dir}, 'Path::Class::Dir', $dir;
}

# Make sure --quiet trumps --verbose.
is_deeply $CLASS->_parse_core_opts([
    '--verbose', '--verbose', '--quiet'
]), { verbosity => 0 }, '--quiet should trump verbosity.';

##############################################################################
# Try short options.
is_deeply $CLASS->_parse_core_opts([
  '-d' => 'mydb',
  '-u' => 'fred',
  '-h' => 'db1',
  '-p' => 5431,
  '-f' => 'foo.plan',
  '-vvv',
]), {
    db_name     => 'mydb',
    db_username => 'fred',
    db_host     => 'db1',
    db_port     => 5431,
    verbosity   => 3,
    plan_file   => 'foo.plan',
}, 'Short options should work';

USAGE: {
    my $mock = Test::MockModule->new('Pod::Usage');
    my %args;
    $mock->mock(pod2usage => sub { %args = @_} );
    ok $CLASS->_pod2usage('sqitch-add', foo => 'bar'), 'Run _pod2usage';
    is_deeply \%args, {
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-verbose'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch-add'),
        '-exitval'  => 2,
        'foo'       => 'bar',
    }, 'Proper args should have been passed to Pod::Usage';
}
