package MockOutput;

use 5.010;
use strict;
use warnings;
use utf8;
use Test::MockModule 0.05;

our $MOCK = Test::MockModule->new('App::Sqitch');

my @mocked = qw(
    trace
    trace_literal
    debug
    debug_literal
    info
    info_literal
    comment
    comment_literal
    emit
    emit_literal
    vent
    vent_literal
    warn
    warn_literal
    page
    page_literal
    prompt
    ask_y_n
);

my $INPUT;
sub prompt_returns { $INPUT = $_[1]; }

my $Y_N;
sub ask_y_n_returns { $Y_N = $_[1]; }

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

$MOCK->mock(prompt => sub {
    shift;
    push @{ $CAPTURED{prompt} } => [@_];
    return $INPUT;
});

$MOCK->mock(ask_y_n => sub {
    shift;
    push @{ $CAPTURED{ask_y_n} } => [@_];
    return $Y_N;
});

sub clear {
    %CAPTURED = map { $_ => [] } @mocked;
}

1;
