#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 158;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;
use Path::Class;
use Term::ANSIColor qw(color);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::ItemFormatter';
require_ok $CLASS;
can_ok $CLASS => qw(
    new
    abbrev
    date_format
    color
    formatter
    format
);

isa_ok my $formatter = $CLASS->new, $CLASS, 'Instantiated object';
ok !$formatter->abbrev, 'Should not be abbreviated by default';
is $formatter->date_format, 'iso', 'Default date format should be "iso"';

###############################################################################
# Test all formatting characters.
my $cdt = App::Sqitch::DateTime->now;
my $pdt = $cdt->clone->subtract(days => 1);
my $local_cdt = $cdt->clone;
$local_cdt->set_time_zone('local');
my $local_pdt = $pdt->clone;
$local_pdt->set_time_zone('local');
my $craw = $cdt->as_string( format => 'raw' );

my $event = {
    event           => 'deploy',
    project         => 'logit',
    change_id       => '000011112222333444',
    change          => 'lolz',
    tags            => [ '@beta', '@gamma' ],
    committer_name  => 'larry',
    committer_email => 'larry@example.com',
    committed_at    => $cdt,
    planner_name    => 'damian',
    planner_email   => 'damian@example.com',
    planned_at      => $pdt,
    note            => "For the LOLZ.\n\nYou know, funny stuff and cute kittens, right?",
    requires        => [qw(foo bar)],
    conflicts       => []
};

if ($^O eq 'MSWin32') {
    require Win32::Locale;
    $_->set( locale => Win32::Locale::get_locale() ) for ($local_cdt, $local_pdt);
} else {
    require POSIX;
    $_->set( locale =>POSIX::setlocale( POSIX::LC_TIME() ) ) for ($local_cdt, $local_pdt);
}

for my $spec (
    ['%e', { event => 'deploy' }, 'deploy' ],
    ['%e', { event => 'revert' }, 'revert' ],
    ['%e', { event => 'fail' },   'fail' ],

    ['%L', { event => 'deploy' }, __ 'Deploy' ],
    ['%L', { event => 'revert' }, __ 'Revert' ],
    ['%L', { event => 'fail' },   __ 'Fail' ],

    ['%l', { event => 'deploy' }, __ 'deploy' ],
    ['%l', { event => 'revert' }, __ 'revert' ],
    ['%l', { event => 'fail' },   __ 'fail' ],

    ['%{event}_',     {}, __ 'Event:    ' ],
    ['%{change}_',    {}, __ 'Change:   ' ],
    ['%{committer}_', {}, __ 'Committer:' ],
    ['%{planner}_',   {}, __ 'Planner:  ' ],
    ['%{by}_',        {}, __ 'By:       ' ],
    ['%{date}_',      {}, __ 'Date:     ' ],
    ['%{committed}_', {}, __ 'Committed:' ],
    ['%{planned}_',   {}, __ 'Planned:  ' ],
    ['%{name}_',      {}, __ 'Name:     ' ],
    ['%{email}_',     {}, __ 'Email:    ' ],
    ['%{requires}_',  {}, __ 'Requires: ' ],
    ['%{conflicts}_', {}, __ 'Conflicts:' ],

    ['%H', { change_id => '123456789' }, '123456789' ],
    ['%h', { change_id => '123456789' }, '123456789' ],
    ['%{5}h', { change_id => '123456789' }, '12345' ],
    ['%{7}h', { change_id => '123456789' }, '1234567' ],

    ['%n', { change => 'foo' }, 'foo'],
    ['%n', { change => 'bar' }, 'bar'],
    ['%o', { project => 'foo' }, 'foo'],
    ['%o', { project => 'bar' }, 'bar'],

    ['%c', { committer_name => 'larry', committer_email => 'larry@example.com'  }, 'larry <larry@example.com>'],
    ['%{n}c', { committer_name => 'damian' }, 'damian'],
    ['%{name}c', { committer_name => 'chip' }, 'chip'],
    ['%{e}c', { committer_email => 'larry@example.com'  }, 'larry@example.com'],
    ['%{email}c', { committer_email => 'damian@example.com' }, 'damian@example.com'],

    ['%{date}c', { committed_at => $cdt }, $cdt->as_string( format => 'iso' ) ],
    ['%{date:rfc}c', { committed_at => $cdt }, $cdt->as_string( format => 'rfc' ) ],
    ['%{d:long}c', { committed_at => $cdt }, $cdt->as_string( format => 'long' ) ],
    ["%{d:cldr:HH'h' mm'm'}c", { committed_at => $cdt }, $local_cdt->format_cldr( q{HH'h' mm'm'} ) ],
    ["%{d:strftime:%a at %H:%M:%S}c", { committed_at => $cdt }, $local_cdt->strftime('%a at %H:%M:%S') ],

    ['%p', { planner_name => 'larry', planner_email => 'larry@example.com'  }, 'larry <larry@example.com>'],
    ['%{n}p', { planner_name => 'damian' }, 'damian'],
    ['%{name}p', { planner_name => 'chip' }, 'chip'],
    ['%{e}p', { planner_email => 'larry@example.com'  }, 'larry@example.com'],
    ['%{email}p', { planner_email => 'damian@example.com' }, 'damian@example.com'],

    ['%{date}p', { planned_at => $pdt }, $pdt->as_string( format => 'iso' ) ],
    ['%{date:rfc}p', { planned_at => $pdt }, $pdt->as_string( format => 'rfc' ) ],
    ['%{d:long}p', { planned_at => $pdt }, $pdt->as_string( format => 'long' ) ],
    ["%{d:cldr:HH'h' mm'm'}p", { planned_at => $pdt }, $local_pdt->format_cldr( q{HH'h' mm'm'} ) ],
    ["%{d:strftime:%a at %H:%M:%S}p", { planned_at => $pdt }, $local_pdt->strftime('%a at %H:%M:%S') ],

    ['%t', { tags => [] }, '' ],
    ['%t', { tags => ['@foo'] }, ' @foo' ],
    ['%t', { tags => ['@foo', '@bar'] }, ' @foo, @bar' ],
    ['%{|}t', { tags => [] }, '' ],
    ['%{|}t', { tags => ['@foo'] }, ' @foo' ],
    ['%{|}t', { tags => ['@foo', '@bar'] }, ' @foo|@bar' ],

    ['%T', { tags => [] }, '' ],
    ['%T', { tags => ['@foo'] }, ' (@foo)' ],
    ['%T', { tags => ['@foo', '@bar'] }, ' (@foo, @bar)' ],
    ['%{|}T', { tags => [] }, '' ],
    ['%{|}T', { tags => ['@foo'] }, ' (@foo)' ],
    ['%{|}T', { tags => ['@foo', '@bar'] }, ' (@foo|@bar)' ],

    ['%r', { requires => [] }, '' ],
    ['%r', { requires => ['foo'] }, ' foo' ],
    ['%r', { requires => ['foo', 'bar'] }, ' foo, bar' ],
    ['%{|}r', { requires => [] }, '' ],
    ['%{|}r', { requires => ['foo'] }, ' foo' ],
    ['%{|}r', { requires => ['foo', 'bar'] }, ' foo|bar' ],

    ['%R', { requires => [] }, '' ],
    ['%R', { requires => ['foo'] }, __('Requires: ') . " foo\n" ],
    ['%R', { requires => ['foo', 'bar'] }, __('Requires: ') . " foo, bar\n" ],
    ['%{|}R', { requires => [] }, '' ],
    ['%{|}R', { requires => ['foo'] }, __('Requires: ') . " foo\n" ],
    ['%{|}R', { requires => ['foo', 'bar'] }, __('Requires: ') . " foo|bar\n" ],

    ['%x', { conflicts => [] }, '' ],
    ['%x', { conflicts => ['foo'] }, ' foo' ],
    ['%x', { conflicts => ['foo', 'bax'] }, ' foo, bax' ],
    ['%{|}x', { conflicts => [] }, '' ],
    ['%{|}x', { conflicts => ['foo'] }, ' foo' ],
    ['%{|}x', { conflicts => ['foo', 'bax'] }, ' foo|bax' ],

    ['%X', { conflicts => [] }, '' ],
    ['%X', { conflicts => ['foo'] }, __('Conflicts:') . " foo\n" ],
    ['%X', { conflicts => ['foo', 'bar'] }, __('Conflicts:') . " foo, bar\n" ],
    ['%{|}X', { conflicts => [] }, '' ],
    ['%{|}X', { conflicts => ['foo'] }, __('Conflicts:') . " foo\n" ],
    ['%{|}X', { conflicts => ['foo', 'bar'] }, __('Conflicts:') . " foo|bar\n" ],

    ['%{yellow}C', {}, '' ],
    ['%{:event}C', { event => 'deploy' }, '' ],
    ['%v', {}, "\n" ],
    ['%%', {}, '%' ],

    ['%s', { note => 'hi there' }, 'hi there' ],
    ['%s', { note => "hi there\nyo" }, 'hi there' ],
    ['%s', { note => "subject line\n\nfirst graph\n\nsecond graph\n\n" }, 'subject line' ],
    ['%{  }s', { note => 'hi there' }, '  hi there' ],
    ['%{xx}s', { note => 'hi there' }, 'xxhi there' ],

    ['%b', { note => 'hi there' }, '' ],
    ['%b', { note => "hi there\nyo" }, 'yo' ],
    ['%b', { note => "subject line\n\nfirst graph\n\nsecond graph\n\n" }, "first graph\n\nsecond graph\n\n" ],
    ['%{  }b', { note => 'hi there' }, '' ],
    ['%{xxx }b', { note => "hi there\nyo" }, "xxx yo" ],
    ['%{x}b', { note => "subject line\n\nfirst graph\n\nsecond graph\n\n" }, "xfirst graph\nx\nxsecond graph\nx\n" ],
    ['%{ }b', { note => "hi there\r\nyo" }, " yo" ],

    ['%B', { note => 'hi there' }, 'hi there' ],
    ['%B', { note => "hi there\nyo" }, "hi there\nyo" ],
    ['%B', { note => "subject line\n\nfirst graph\n\nsecond graph\n\n" }, "subject line\n\nfirst graph\n\nsecond graph\n\n" ],
    ['%{  }B', { note => 'hi there' }, '  hi there' ],
    ['%{xxx }B', { note => "hi there\nyo" }, "xxx hi there\nxxx yo" ],
    ['%{x}B', { note => "subject line\n\nfirst graph\n\nsecond graph\n\n" }, "xsubject line\nx\nxfirst graph\nx\nxsecond graph\nx\n" ],
    ['%{ }B', { note => "hi there\r\nyo" }, " hi there\r\n yo" ],

    ['%{change}a',    $event, "change    $event->{change}\n" ],
    ['%{change_id}a', $event, "change_id $event->{change_id}\n" ],
    ['%{event}a',     $event, "event     $event->{event}\n" ],
    ['%{tags}a',      $event, 'tags      ' . join(', ', @{ $event->{tags} }) . "\n" ],
    ['%{requires}a',  $event, 'requires  ' . join(', ', @{ $event->{requires} }) . "\n" ],
    ['%{conflicts}a', $event, '' ],
    ['%{committer_name}a', $event, "committer_name $event->{committer_name}\n" ],
    ['%{committed_at}a',   $event, "committed_at $craw\n" ],
) {
    (my $desc = $spec->[2]) =~ s/\n/[newline]/g;
    is $formatter->format( $spec->[0], $spec->[1] ), $spec->[2],
        qq{Format "$spec->[0]" should output "$desc"};
}

throws_ok { $formatter->format( '%_', {} ) } 'App::Sqitch::X',
    'Should get exception for format "%_"';
is $@->ident, 'format', '%_ error ident should be "format"';
is $@->message, __ 'No label passed to the _ format',
    '%_ error message should be correct';
throws_ok { $formatter->format( '%{foo}_', {} ) } 'App::Sqitch::X',
    'Should get exception for unknown label in format "%_"';
is $@->ident, 'format', 'Invalid %_ label error ident should be "format"';
is $@->message, __x(
    'Unknown label "{label}" passed to the _ format',
    label => 'foo'
), 'Invalid %_ label error message should be correct';

ok $formatter = $CLASS->new( abbrev => 4 ),
    'Instantiate with abbrev => 4';
is $formatter->format( '%h', { change_id => '123456789' } ),
    '1234', '%h should respect abbrev';
is $formatter->format( '%H', { change_id => '123456789' } ),
    '123456789', '%H should not respect abbrev';

ok $formatter = $CLASS->new( date_format => 'rfc' ),
    'Instantiate with date_format => "rfc"';
is $formatter->format( '%{date}c', { committed_at => $cdt } ),
    $cdt->as_string( format => 'rfc' ),
    '%{date}c should respect the date_format attribute';
is $formatter->format( '%{d:iso}c', { committed_at => $cdt } ),
    $cdt->as_string( format => 'iso' ),
    '%{iso}c should override the date_format attribute';

throws_ok { $formatter->format( '%{foo}a', {}) } 'App::Sqitch::X',
    'Should get exception for unknown attribute passed to %a';
is $@->ident, 'format', '%a error ident should be "log"';
is $@->message, __x(
    '{attr} is not a valid change attribute', attr => 'foo'
), '%a error message should be correct';

# Test colors.
delete $ENV{ANSI_COLORS_DISABLED};
ok $formatter = $CLASS->new( color => 'always' ),
    'Construct with color "always"';
for my $color (qw(yellow red blue cyan magenta)) {
    is $formatter->format( "%{$color}C", {} ), color($color),
        qq{Format "%{$color}C" should output }
        . color($color) . $color . color('reset');
}

for my $spec (
    [ ':event', { event => 'deploy' }, 'green', 'deploy' ],
    [ ':event', { event => 'revert' }, 'blue',  'revert' ],
    [ ':event', { event => 'fail'   }, 'red',   'fail'   ],
) {
    is $formatter->format( "%{$spec->[0]}C", $spec->[1] ), color($spec->[2]),
        qq{Format "%{$spec->[0]}C" on "$spec->[3]" should output }
        . color($spec->[2]) . $spec->[2] . color('reset');
}

throws_ok { $formatter->format( '%{BLUELOLZ}C', {} ) } 'App::Sqitch::X',
    'Should get an error for an invalid color';
is $@->ident, 'format', 'Invalid color error ident should be "log"';
is $@->message, __x(
    '{color} is not a valid ANSI color', color => 'BLUELOLZ'
), 'Invalid color error message should be correct';

# Make sure color "never" works.
ok $formatter = $CLASS->new( color => 'never' ),
    'Construct with color "never"';
for my $color (qw(yellow red blue cyan magenta)) {
    is $formatter->format( "%{$color}C", {} ), '',
        qq{Format "%{$color}C" should not output a color};
}

# Make sure an unknown format character throws a proper exception.
throws_ok { $formatter->format('%Z', {}) } 'App::Sqitch::X',
    'Should get an exception for a bad format code';
is $@->ident, 'format',
    'bad format code format error ident should be "log"';
is $@->message, __x(
    'Unknown format code "{code}"', code => 'Z',
), 'bad format code format error message should be correct';
