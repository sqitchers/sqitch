#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 59;
use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;
use Path::Class;
use Term::ANSIColor qw(color);
use URI;
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::log';
require_ok $CLASS;

my $uri = URI->new('https://github.com/theory/sqitch/');
ok my $sqitch = App::Sqitch->new(
    uri     => $uri,
    top_dir => Path::Class::Dir->new('sql'),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $log = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'log',
    config  => $config,
}), $CLASS, 'log command';

can_ok $log, qw(
    change_pattern
    actor_pattern
    max_count
    skip
    reverse
    abbrev
    format
    date_format
    color
    options
    execute
    configure
);

is_deeply [$CLASS->options], [qw(
    event=s@
    change-pattern|change|c=s
    actor-pattern|actor|a=s
    max-count|n=i
    skip=i
    reverse!
    color=s
    no-color
    abbrev=i
    format|f=s
    date-format|date=s
)], 'Options should be correct';

##############################################################################
# Test configure().
my $cmock = Test::MockModule->new('App::Sqitch::Config');

# Test date_format validation.
is_deeply $CLASS->configure($config, {}), {},
    'Should get empty hash for no config or options';
$cmock->mock( get => 'nonesuch' );
throws_ok { $CLASS->configure($config, {}), {} } 'App::Sqitch::X',
    'Should get error for invalid date format in config';
is $@->ident, 'datetime',
    'Invalid date format error ident should be "datetime"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'nonesuch',
), 'Invalid date format error message should be correct';
$cmock->unmock_all;

throws_ok { $CLASS->configure($config, { 'date-format' => 'non'}), {} }
    'App::Sqitch::X',
    'Should get error for invalid date format in optsions';
is $@->ident, 'datetime',
    'Invalid date format error ident should be "log"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'non',
), 'Invalid date format error message should be correct';

# Test format validation.
$cmock->mock( get => sub {
    my ($self, %p) = @_;
    return 'nonesuch' if $p{key} eq 'log.format';
    return undef;
});
throws_ok { $CLASS->configure($config, {}), {} } 'App::Sqitch::X',
    'Should get error for invalid format in config';
is $@->ident, 'log',
    'Invalid format error ident should be "log"';
is $@->message, __x(
    'Unknown log format "{format}"',
    format => 'nonesuch',
), 'Invalid format error message should be correct';
$cmock->unmock_all;

throws_ok { $CLASS->configure($config, { format => 'non'}), {} }
    'App::Sqitch::X',
    'Should get error for invalid format in optsions';
is $@->ident, 'log',
    'Invalid format error ident should be "log"';
is $@->message, __x(
    'Unknown log format "{format}"',
    format => 'non',
), 'Invalid format error message should be correct';

# Test color configuration.
is_deeply$CLASS->configure( $config, {'no-color', 1 } ), {
    color => 'never'
}, 'Configuration should respect --no-color, setting "never"';

my $config_color = 'auto';
$cmock->mock( get => sub {
    my ($self, %p) = @_;
    return $config_color if $p{key} eq 'log.color';
    return undef;
});

my $log_config = {};
$cmock->mock( get_section => sub { $log_config } );

is_deeply $CLASS->configure( $config, {'no-color', 1 } ), {
    color => 'never'
}, 'Configuration should respect --no-color even when configure is set';

NEVER: {
    local $ENV{ANSI_COLORS_DISABLED};
    $config_color = 'never';
    $log_config = { color => $config_color };
    is_deeply $CLASS->configure( $config, $log_config ),  { color => 'never' },
        'Configuration should respect color option';
    ok $ENV{ANSI_COLORS_DISABLED}, 'Colors should be disabled for "never"';

    # Try it with config.
    delete $ENV{ANSI_COLORS_DISABLED};
    $log_config = { color => $config_color };
    is_deeply $CLASS->configure( $config, {} ), { color => 'never' },
        'Configuration should respect color config';
    ok $ENV{ANSI_COLORS_DISABLED}, 'Colors should be disabled for "never"';
}

ALWAYS: {
    local $ENV{ANSI_COLORS_DISABLED};
    $config_color = 'always';
    $log_config = { color => $config_color };
    is_deeply $CLASS->configure( $config, $log_config ),  { color => 'always' },
        'Configuration should respect color option';
    ok !$ENV{ANSI_COLORS_DISABLED}, 'Colors should be enabled for "always"';

    # Try it with config.
    delete $ENV{ANSI_COLORS_DISABLED};
    $log_config = { color => $config_color };
    is_deeply $CLASS->configure( $config, {} ), { color => 'always' },
        'Configuration should respect color config';
    ok !$ENV{ANSI_COLORS_DISABLED}, 'Colors should be enabled for "always"';
}

AUTO: {
    $config_color = 'auto';
    $log_config = { color => $config_color };
    for my $enabled (0, 1) {
        local $ENV{ANSI_COLORS_DISABLED} = $enabled;
        is_deeply $CLASS->configure( $config, $log_config ),  { color => 'auto' },
            'Configuration should respect color option';
        is $ENV{ANSI_COLORS_DISABLED}, $enabled,
            'Auto color option should change nothing';

        # Try it with config.
        $log_config = { color => $config_color };
        is_deeply $CLASS->configure( $config, {} ), { color => 'auto' },
            'Configuration should respect color config';
        is $ENV{ANSI_COLORS_DISABLED}, $enabled,
            'Auto color config should change nothing';
    }
}

$cmock->unmock_all;

###############################################################################
# Test named formats.
my $dt = App::Sqitch::DateTime->now;
my $event = {
    event     => 'deploy',
    change_id => '000011112222333444',
    change    => 'lolz',
    tags      => ['@beta', '@gamma'],
    logged_by => 'larry',
    logged_at => $dt,
};

my $iso = $dt->as_string( format => 'iso' );
for my $spec (
    [ raw => "event   deploy\n"
           . "change  000011112222333444 (\@beta, \@gamma)\n"
           . "name    lolz\n"
           . "date    $iso\n"
           . "agent   larry\n"
    ],
    [ full => color('yellow') . __ 'Change:' . ' 000011112222333444'
        . color('reset') . " (\@beta, \@gamma)\n"
        . __ 'Event:' . "  deploy\n"
        . __ 'Name:'  . "   lolz\n"
        . __ 'Date:'  . "   __DATE__\n"
        . __ 'By:'    . "     larry\n"
    ],
    [ long => color('yellow') . __ 'Deploy' . ' 000011112222333444'
        . color('reset') . " (\@beta, \@gamma)\n"
        . __ 'Name:'  . "   lolz\n"
        . __ 'Date:'  . "   __DATE__\n"
        . __ 'By:'    . "     larry\n"
    ],
    [ medium => color('yellow') . __ 'Deploy' . ' 000011112222333444'
        . color('reset') . " (\@beta, \@gamma)\n"
        . __ 'Name:'  . "   lolz\n"
        . __ 'Date:'  . "   __DATE__\n"
    ],
    [ short => color('yellow') . '000011112222333444' . color('reset') . "\n"
        . $dt->as_string( format => 'short' ) . ' - '
        . __ 'deploy' . " lolz - larry\n"
    ],
    [ oneline => '000011112222333444 deploy lolz' ],
) {
    my $format = $CLASS->configure( $config, { format => $spec->[0] } )->{format};
    ok my $log = $CLASS->new( sqitch => $sqitch, format => $format ),
        qq{Instantiate with format "$spec->[0]"};
    (my $exp = $spec->[1]) =~ s/__DATE__/$iso/;
    is $log->formatter->format( $log->format, $event ), $exp,
        qq{Format "$spec->[0]" should output correctly};

    if ($spec->[1] =~ /__DATE__/) {
        # Test different date formats.
        for my $date_format (qw(rfc long medium)) {
            ok my $log = $CLASS->new(
                sqitch => $sqitch,
                format => $format,
                date_format => $date_format,
            ), qq{Instantiate with format "$spec->[0]" and date format "$date_format"};
            my $date = $dt->as_string( format => $date_format );
            (my $exp = $spec->[1]) =~ s/__DATE__/$date/;
            is $log->formatter->format( $log->format, $event ), $exp,
                qq{Format "$spec->[0]" and date format "$date_format" should output correctly};
        }
    }

    if ($spec->[1] =~ s/\s+[(]?[@]beta,\s+[@]gamma[)]?//) {
        # Test without tags.
        local $event->{tags} = [];
        (my $exp = $spec->[1]) =~ s/__DATE__/$iso/;
        is $log->formatter->format( $log->format, $event ), $exp,
            qq{Format "$spec->[0]" should output correctly without tags};
    }
}

###############################################################################
# Test all formatting characters.
my $formatter = $log->formatter;
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

    ['%{event}_', {}, __ 'Event: ' ],
    ['%{change}_', {}, __ 'Change:' ],
    ['%{actor}_', {}, __ 'Actor: ' ],
    ['%{by}_', {}, __ 'By:    ' ],
    ['%{date}_', {}, __ 'Date:  ' ],
    ['%{name}_', {}, __ 'Name:  ' ],

    ['%H', { change_id => '123456789' }, '123456789' ],
    ['%h', { change_id => '123456789' }, '123456789' ],
    ['%{5}h', { change_id => '123456789' }, '12345' ],
    ['%{7}h', { change_id => '123456789' }, '1234567' ],

    ['%c', { change => 'foo' }, 'foo'],
    ['%c', { change => 'bar' }, 'bar'],

    ['%a', { logged_by => 'larry'  }, 'larry'],
    ['%a', { logged_by => 'damian' }, 'damian'],

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

    ['%n', {}, "\n" ],

    ['%d', { logged_at => $dt }, $dt->as_string( format => 'iso' ) ],
    ['%{rfc}d', { logged_at => $dt }, $dt->as_string( format => 'rfc' ) ],
    ['%{long}d', { logged_at => $dt }, $dt->as_string( format => 'long' ) ],

    ['%{yellow}C', {}, '' ],
) {
    (my $desc = $spec->[2]) =~ s/\n/[newline]/g;
    is $formatter->format( $spec->[0], $spec->[1] ), $spec->[2],
        qq{Format "$spec->[0]" should output "$desc"};
}

throws_ok { $formatter->format( '%_', {} ) } 'App::Sqitch::X',
    'Should get exception for format "%_"';
is $@->ident, 'log', '%_ error ident should be "log"';
is $@->message, __ 'No label passed to the _ format',
    '%_ error message should be correct';

ok $log = $CLASS->new( sqitch => $sqitch, abbrev => 4 ),
    'Instantiate with abbrev => 4';
is $log->formatter->format( '%h', { change_id => '123456789' } ),
    '1234', '%h should respect abbrev';
is $log->formatter->format( '%H', { change_id => '123456789' } ),
    '123456789', '%H should not respect abbrev';

ok $log = $CLASS->new( sqitch => $sqitch, date_format => 'rfc' ),
    'Instantiate with date_format => "rfc"';
is $log->formatter->format( '%d', { logged_at => $dt } ),
    $dt->as_string( format => 'rfc' ),
    '%d should respect the date_format attribute';
is $log->formatter->format( '%{iso}d', { logged_at => $dt } ),
    $dt->as_string( format => 'iso' ),
    '%{iso}d should override the date_format attribute';

delete $ENV{ANSI_COLORS_DISABLED};
for my $color (qw(yellow red blue cyan magenta)) {
    is $formatter->format( "%{$color}C", {} ), color($color),
        qq{Format "%{$color}C" should output }
        . color($color) . $color . color('reset');
}

throws_ok { $formatter->format( '%{BLUELOLZ}C', {} ) } 'App::Sqitch::X',
    'Should get an error for an invalid color';
is $@->ident, 'log', 'Invalid color error ident should be "log"';
is $@->message, __x(
    '{color} is not a valid ANSI color', color => 'BLUELOLZ'
), 'Invalid color error message should be correct';
