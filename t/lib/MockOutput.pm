package MockOutput;

use 5.010;
use strict;
use warnings;
use utf8;
use Test::MockModule 0.05;

our $MOCK = Test::MockModule->new('App::Sqitch');

my @mocked = qw(
    trace
    debug
    info
    comment
    emit
    vent
    warn
    page
    prompt
    ask_y_n
);

my %CAPTURED;

__PACKAGE__->clear;

for my $meth (@mocked) {
    $MOCK->mock($meth => sub {
        shift;
        push @{ $CAPTURED{$meth} } => [@_];
    });

    my $get = sub {
        my $ret = $CAPTURED{$meth};
        $CAPTURED{$meth} = [];
        return $ret;
    };

    no strict 'refs';
    *{"get_$meth"} = $get;
}

sub clear {
    %CAPTURED = map { $_ => [] } @mocked;
}

1;
