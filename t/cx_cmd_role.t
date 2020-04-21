#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More;
use Path::Class;
use App::Sqitch;
use lib 't/lib';
use TestConfig;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch); # XXX Until deprecation removed below.

my $ROLE;

BEGIN {
    $ROLE = 'App::Sqitch::Role::ContextCommand';
    use_ok $ROLE or die;
}

COMMAND: {
    # Stub out a command.
    package App::Sqitch::Command::click;
    use Moo;
    extends 'App::Sqitch::Command';
    with $ROLE;
    $INC{'App/Sqitch/Command/click.pm'} = __FILE__;

    sub options {
        return qw(
            foo
            quack|k=s
        );
    }
}

my $CLASS = 'App::Sqitch::Command::click';
can_ok $CLASS, 'does';
ok $CLASS->does($ROLE), "$CLASS does $ROLE";

is_deeply [$CLASS->options], [qw(
    foo
    quack|k=s
    plan-file|f=s
    top-dir=s
)], 'Options should include context options';


# Silence warnings.
my $mock = Test::MockModule->new('App::Sqitch');
my $warning;
$mock->mock(warn => sub { $warning = $_[1] });

##############################################################################
# Test configure.
my $opts = {};
my $config = TestConfig->new;
is_deeply $CLASS->configure($config, $opts), { _cx => [] },
    'Should get no params for no options';

$opts = {
    top_dir => '',
    plan_file => '0',
};
is_deeply $CLASS->configure($config, $opts), { _cx => [] },
    'Should get no params for empty options';
is $warning, undef, 'Should have no warning';

$opts = { top_dir => 't' };
my @params = ( top_dir => dir 't');
is_deeply $CLASS->configure($config, $opts), { _cx => \@params },
    'Should get top_dir';
is $warning, __x(
    "  Option --top-dir is deprecated for {command} and other non-configuration commands.\n  Use --chdir instead.",
    command => $CLASS->command,
), 'Should have --top-dir deprecation warning';
$warning = undef;

$opts = {
    top_dir   => 'lib',
    plan_file => 'README.md',
    quack     => 'woof',
};
@params = (
    top_dir   => dir('lib'),
    plan_file => file('README.md'),
);
is_deeply $CLASS->configure($config, $opts),
    { _cx => \@params, quack => 'woof' },
    'Should collect params';
is $warning, __x(
    "  Option --top-dir is deprecated for {command} and other non-configuration commands.\n  Use --chdir instead.",
    command => $CLASS->command,
), 'Should have --top-dir deprecation warning again';

##############################################################################
# Test target_params.
my $sqitch = App::Sqitch->new(config => $config);
isa_ok my $cmd = $CLASS->new(
    sqitch => $sqitch,
    quack  => 'beep',
    _cx => \@params,
), $CLASS;

is_deeply [$cmd->target_params], [sqitch => $sqitch, @params],
    'Should get context params from target_params';

done_testing;
