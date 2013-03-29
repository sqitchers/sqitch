package EngineTest;
use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use Test::More;

sub run {
    my ( $self, %p ) = @_;

    my $class         = $p{class};
    my @sqitch_params = @{ $p{sqitch_params} };
    my $user1_name    = 'Marge Simpson';
    my $user1_email   = 'marge@example.com';

    subtest 'live database' => sub {
        my $sqitch = App::Sqitch->new(
            @sqitch_params,
            user_name  => $user1_name,
            user_email => $user1_email,
        );
        my $engine = $class->new(sqitch => $sqitch, @{ $p{engine_params} || [] });
        if (my $code = $p{skip_unless}) {
            try {
                $code->( $engine ) || die 'NO';
            } catch {
                plan skip_all => sprintf(
                    'Unable to live-test %s engine: %s',
                    $class->name,
                    eval { $_->message } || $_
                );
            };
        }

        ok $engine, 'Engine initialized';
    };
}

1;
