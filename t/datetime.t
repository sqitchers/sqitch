#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 33;
#use Test::More 'no_plan';
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
require POSIX;

my $CLASS = 'App::Sqitch::DateTime';
require_ok $CLASS;

ok my $dt = $CLASS->now, 'Construct a datetime object';
is_deeply [$dt->as_string_formats], [qw(
    raw
    iso
    iso8601
    rfc
    rfc2822
    full
    long
    medium
    short
)], 'as_string_formats should be correct';

my $rfc = do {
    my $clone = $dt->clone;
    $clone->set_time_zone('local');
    $clone->set( locale => 'en_US' );
    ( my $rv = $clone->strftime('%a, %d %b %Y %H:%M:%S %z') ) =~ s/\+0000$/-0000/;
    $rv;
};

my $iso = do {
    my $clone = $dt->clone;
    $clone->set_time_zone('local');
    join ' ', $clone->ymd('-'), $clone->hms(':'), $clone->strftime('%z')
};

my $ldt = do {
    my $clone = $dt->clone;
    $clone->set_time_zone('local');
  # sometimes Windows returns things DateTime doesn't like ("English_United States.1252")
  eval {
    $clone->set(locale => POSIX::setlocale(POSIX::LC_TIME()) );
  } or diag $@;
    $clone;
};

my $raw = do {
    my $clone = $dt->clone;
    $clone->set_time_zone('UTC');
    $clone->iso8601 . 'Z';
};

for my $spec (
    [ full    => $ldt->format_cldr( $ldt->locale->datetime_format_full )],
    [ long    => $ldt->format_cldr( $ldt->locale->datetime_format_long )],
    [ medium  => $ldt->format_cldr( $ldt->locale->datetime_format_medium )],
    [ short   => $ldt->format_cldr( $ldt->locale->datetime_format_short )],
    [ raw     => $raw ],
    [ ''      => $raw ],
    [ iso     => $iso ],
    [ iso8601 => $iso ],
    [ rfc     => $rfc ],
    [ rfc2822 => $rfc ],
    [ q{cldr:HH'h' mm'm'} => $ldt->format_cldr( q{HH'h' mm'm'} ) ],
    [ 'strftime:%a at %H:%M:%S' => $ldt->strftime('%a at %H:%M:%S') ],
) {
    my $clone = $dt->clone;
    $clone->set_time_zone('UTC');
    is $dt->as_string( format => $spec->[0] ), $spec->[1],
        qq{Date format "$spec->[0]" should yield "$spec->[1]"};
    ok $dt->validate_as_string_format($spec->[0]),
        qq{Format "$spec->[0]" should be valid} if $spec->[0];
}

throws_ok { $dt->validate_as_string_format('nonesuch') } 'App::Sqitch::X',
    'Should get error for invalid date format';
is $@->ident, 'datetime', 'Invalid date format error ident should be "datetime"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'nonesuch',
), 'Invalid date format error message should be correct';

throws_ok { $dt->as_string( format => 'nonesuch' ) } 'App::Sqitch::X',
    'Should get error for invalid as_string format param';
is $@->ident, 'datetime', 'Invalid date format error ident should be "datetime"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'nonesuch',
), 'Invalid date format error message should be correct';
