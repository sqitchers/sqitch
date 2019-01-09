#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More;
use App::Sqitch;
use lib 't/lib';
use TestConfig;

my $ROLE;

BEGIN {
    $ROLE = 'App::Sqitch::Role::ConnectingCommand';
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
    db-name|d=s
    db-user|db-username|u=s
    db-host|h=s
    db-port|p=i
    registry=s
    client|db-client=s
)], 'Options should include connection options';

##############################################################################
# Test configure.
my $opts = {};
my $config = TestConfig->new;
my @params;
is_deeply $CLASS->configure($config, $opts), { _params => \@params },
    'Should get no params for no options';

$opts->{db_name} = 'disco';
push @params => dbname => 'disco';
is_deeply $CLASS->configure($config, $opts), { _params => \@params },
    'Should get no dbname for --db-name';

$opts = {
    db_user  => 'theory',
    db_host  => 'justatheory.com',
    db_port  => 9876,
    db_name  => 'funk',
    registry => 'crickets',
    client   => '/bin/true',
    quack    => 'woof',
};
@params = (
    user     => 'theory',
    host     => 'justatheory.com',
    port     => 9876,
    dbname   => 'funk',
    registry => 'crickets',
    client   => '/bin/true',
);
is_deeply $CLASS->configure($config, $opts),
    { _params => \@params, quack => 'woof' },
    'Should collect params';

##############################################################################
# Test target_params.
my $sqitch = App::Sqitch->new(config => $config);
isa_ok my $cmd = $CLASS->new(
    sqitch => $sqitch,
    quack  => 'beep',
    _params => \@params,
), $CLASS;

is_deeply [$cmd->target_params], [sqitch => $sqitch, @params],
    'Should get connection params from target_params';

done_testing;
