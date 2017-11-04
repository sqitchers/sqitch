#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 252;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Test::MockModule;
use Path::Class;
use Term::ANSIColor qw(color);
use Encode;
use lib 't/lib';
use MockOutput;
use LC;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::log';
require_ok $CLASS;

my $plan_file = Path::Class::File->new('t/sql/sqitch.plan')->stringify;
ok my $sqitch = App::Sqitch->new(
    options => {
        engine    => 'sqlite',
        top_dir   => Path::Class::Dir->new('test-log')->stringify,
        plan_file => $plan_file,
    },
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $log = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'log',
    config  => $config,
}), $CLASS, 'log command';

can_ok $log, qw(
    target
    change_pattern
    project_pattern
    committer_pattern
    max_count
    skip
    reverse
    format
    options
    execute
    configure
);

is_deeply [$CLASS->options], [qw(
    event=s@
    target|t=s
    change-pattern|change=s
    project-pattern|project=s
    committer-pattern|committer=s
    format|f=s
    date-format|date=s
    max-count|n=i
    skip=i
    reverse!
    color=s
    no-color
    abbrev=i
    oneline
)], 'Options should be correct';

##############################################################################
# Test database.
is $log->target, undef, 'Default target should be undef';
isa_ok $log = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new status with target';
is $log->target, 'foo', 'Should have target "foo"';

##############################################################################
# Test configure().
my $cmock = Test::MockModule->new('App::Sqitch::Config');

# Test date_format validation.
my $configured = $CLASS->configure($config, {});
isa_ok delete $configured->{formatter}, 'App::Sqitch::ItemFormatter', 'Formatter';
is_deeply $configured, {},
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

throws_ok { $CLASS->configure($config, { date_format => 'non'}), {} }
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
$configured = $CLASS->configure( $config, { no_color => 1 } );
is $configured->{formatter}->color, 'never',
    'Configuration should respect --no-color, setting "never"';

# Test oneline configuration.
$configured = $CLASS->configure( $config, { oneline => 1 });
is $configured->{format}, '%{:event}C%h %l%{reset}C %o:%n %s',
    '--oneline should set format';
is $configured->{formatter}{abbrev}, 6, '--oneline should set abbrev to 6';

$configured = $CLASS->configure( $config, { oneline => 1, format => 'format:foo', abbrev => 5 });
is $configured->{format}, 'foo', '--oneline should not override --format';
is $configured->{formatter}{abbrev}, 5, '--oneline should not overrride --abbrev';

my $config_color = 'auto';
$cmock->mock( get => sub {
    my ($self, %p) = @_;
    return $config_color if $p{key} eq 'log.color';
    return undef;
});

my $log_config = {};
$cmock->mock( get_section => sub { $log_config } );

$configured = $CLASS->configure( $config, { no_color => 1 } );

is $configured->{formatter}->color, 'never',
    'Configuration should respect --no-color even when configure is set';

NEVER: {
    $config_color = 'never';
    $log_config = { color => $config_color };
    my $configured = $CLASS->configure( $config, $log_config );
    is $configured->{formatter}->color, 'never',
        'Configuration should respect color option';

    # Try it with config.
    $log_config = { color => $config_color };
    $configured = $CLASS->configure( $config, {} );
    is $configured->{formatter}->color, 'never',
        'Configuration should respect color config';
}

ALWAYS: {
    $config_color = 'always';
    $log_config = { color => $config_color };
    my $configured = $CLASS->configure( $config, $log_config );
    is_deeply $configured->{formatter}->color, 'always',
        'Configuration should respect color option';

    # Try it with config.
    $log_config = { color => $config_color };
    $configured = $CLASS->configure( $config, {} );
    is_deeply $configured->{formatter}->color, 'always',
        'Configuration should respect color config';
}

AUTO: {
    $config_color = 'auto';
    $log_config = { color => $config_color };
    for my $enabled (0, 1) {
        my $configured = $CLASS->configure( $config, $log_config );
        is_deeply $configured->{formatter}->color, 'auto',
            'Configuration should respect color option';

        # Try it with config.
        $log_config = { color => $config_color };
        $configured = $CLASS->configure( $config, {} );
        is_deeply $configured->{formatter}->color, 'auto',
            'Configuration should respect color config';
    }
}

$cmock->unmock_all;

###############################################################################
# Test named formats.
my $cdt = App::Sqitch::DateTime->now;
my $pdt = $cdt->clone->subtract(days => 1);
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

my $ciso = $cdt->as_string( format => 'iso' );
my $craw = $cdt->as_string( format => 'raw' );
my $piso = $pdt->as_string( format => 'iso' );
my $praw = $pdt->as_string( format => 'raw' );
for my $spec (
    [ raw => "deploy 000011112222333444 (\@beta, \@gamma)\n"
        . "name      lolz\n"
        . "project   logit\n"
        . "requires  foo, bar\n"
        . "planner   damian <damian\@example.com>\n"
        . "planned   $praw\n"
        . "committer larry <larry\@example.com>\n"
        . "committed $craw\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ full =>  __('Deploy') . " 000011112222333444 (\@beta, \@gamma)\n"
        . __('Name:     ') . " lolz\n"
        . __('Project:  ') . " logit\n"
        . __('Requires: ') . " foo, bar\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n"
        . __('Planned:  ') . " __PDATE__\n"
        . __('Committer:') . " larry <larry\@example.com>\n"
        . __('Committed:') . " __CDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ long =>  __('Deploy') . " 000011112222333444 (\@beta, \@gamma)\n"
        . __('Name:     ') . " lolz\n"
        . __('Project:  ') . " logit\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n"
        . __('Committer:') . " larry <larry\@example.com>\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ medium =>  __('Deploy') . " 000011112222333444\n"
        . __('Name:     ') . " lolz\n"
        . __('Committer:') . " larry <larry\@example.com>\n"
        . __('Date:     ') . " __CDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ short =>  __('Deploy') . " 000011112222333444\n"
        . __('Name:     ') . " lolz\n"
        . __('Committer:') . " larry <larry\@example.com>\n\n"
        . "    For the LOLZ.\n",
    ],
    [ oneline => '000011112222333444 ' . __('deploy') . ' logit:lolz For the LOLZ.' ],
) {
    local $ENV{ANSI_COLORS_DISABLED} = 1;
    my $configured = $CLASS->configure( $config, { format => $spec->[0] } );
    my $format = $configured->{format};
    ok my $log = $CLASS->new( sqitch => $sqitch, %{ $configured } ),
        qq{Instantiate with format "$spec->[0]"};
    (my $exp = $spec->[1]) =~ s/__CDATE__/$ciso/;
    $exp =~ s/__PDATE__/$piso/;
    is $log->formatter->format( $log->format, $event ), $exp,
        qq{Format "$spec->[0]" should output correctly};

    if ($spec->[1] =~ /__CDATE__/) {
        # Test different date formats.
        for my $date_format (qw(rfc long medium)) {
            ok my $log = $CLASS->new(
                sqitch => $sqitch,
                format => $format,
                formatter => App::Sqitch::ItemFormatter->new(date_format => $date_format),
            ), qq{Instantiate with format "$spec->[0]" and date format "$date_format"};
            my $date = $cdt->as_string( format => $date_format );
            (my $exp = $spec->[1]) =~ s/__CDATE__/$date/;
            $date = $pdt->as_string( format => $date_format );
            $exp =~ s/__PDATE__/$date/;
            is $log->formatter->format( $log->format, $event ), $exp,
                qq{Format "$spec->[0]" and date format "$date_format" should output correctly};
        }
    }

    if ($spec->[1] =~ s/\s+[(]?[@]beta,\s+[@]gamma[)]?//) {
        # Test without tags.
        local $event->{tags} = [];
        (my $exp = $spec->[1]) =~ s/__CDATE__/$ciso/;
        $exp =~ s/__PDATE__/$piso/;
        is $log->formatter->format( $log->format, $event ), $exp,
            qq{Format "$spec->[0]" should output correctly without tags};
    }
}

###############################################################################
# Test all formatting characters.
my $local_cdt = $cdt->clone;
$local_cdt->set_time_zone('local');
$local_cdt->set_locale($LC::TIME);
my $local_pdt = $pdt->clone;
$local_pdt->set_time_zone('local');
$local_pdt->set_locale($LC::TIME);

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
    local $ENV{ANSI_COLORS_DISABLED} = 1;
    (my $desc = encode_utf8 $spec->[2]) =~ s/\n/[newline]/g;
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

ok $log = $CLASS->new(
    sqitch    => $sqitch,
    formatter => App::Sqitch::ItemFormatter->new(abbrev => 4)
), 'Instantiate with abbrev => 4';
is $log->formatter->format( '%h', { change_id => '123456789' } ),
    '1234', '%h should respect abbrev';
is $log->formatter->format( '%H', { change_id => '123456789' } ),
    '123456789', '%H should not respect abbrev';

ok $log = $CLASS->new(
    sqitch    => $sqitch,
    formatter => App::Sqitch::ItemFormatter->new(date_format => 'rfc')
), 'Instantiate with date_format => "rfc"';
is $log->formatter->format( '%{date}c', { committed_at => $cdt } ),
    $cdt->as_string( format => 'rfc' ),
    '%{date}c should respect the date_format attribute';
is $log->formatter->format( '%{d:iso}c', { committed_at => $cdt } ),
    $cdt->as_string( format => 'iso' ),
    '%{iso}c should override the date_format attribute';

throws_ok { $formatter->format( '%{foo}a', {}) } 'App::Sqitch::X',
    'Should get exception for unknown attribute passed to %a';
is $@->ident, 'format', '%a error ident should be "format"';
is $@->message, __x(
    '{attr} is not a valid change attribute', attr => 'foo'
), '%a error message should be correct';


delete $ENV{ANSI_COLORS_DISABLED};
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

# Make sure other colors work.
my $yellow = color('yellow') . '%s' . color('reset');
my $green  = color('green')  . '%s' . color('reset');
$event->{conflicts} = [qw(dr_evil)];
for my $spec (
    [ full => sprintf($green, __ ('Deploy') . ' 000011112222333444')
        . " (\@beta, \@gamma)\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Project:  ') . " logit\n"
        . __ ('Requires: ') . " foo, bar\n"
        . __ ('Conflicts:') . " dr_evil\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n"
        . __ ('Planned:  ') . " __PDATE__\n"
        . __ ('Committer:') . " larry <larry\@example.com>\n"
        . __ ('Committed:') . " __CDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ long => sprintf($green, __ ('Deploy') . ' 000011112222333444')
        . " (\@beta, \@gamma)\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Project:  ') . " logit\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n"
        . __ ('Committer:') . " larry <larry\@example.com>\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ medium => sprintf($green, __ ('Deploy') . ' 000011112222333444') . "\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Committer:') . " larry <larry\@example.com>\n"
        . __ ('Date:     ') . " __CDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ short => sprintf($green, __ ('Deploy') . ' 000011112222333444') . "\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Committer:') . " larry <larry\@example.com>\n\n"
        . "    For the LOLZ.\n",
    ],
    [ oneline => sprintf "$green %s %s", '000011112222333444' . ' '
        . __('deploy'), 'logit:lolz', 'For the LOLZ.',
    ],
) {
    my $format = $CLASS->configure( $config, { format => $spec->[0] } )->{format};
    ok my $log = $CLASS->new( sqitch => $sqitch, format => $format ),
        qq{Instantiate with format "$spec->[0]" again};
    (my $exp = $spec->[1]) =~ s/__CDATE__/$ciso/;
    $exp =~ s/__PDATE__/$piso/;
    is $log->formatter->format( $log->format, $event ), $exp,
        qq{Format "$spec->[0]" should output correctly with color};
}

throws_ok { $formatter->format( '%{BLUELOLZ}C', {} ) } 'App::Sqitch::X',
    'Should get an error for an invalid color';
is $@->ident, 'format', 'Invalid color error ident should be "format"';
is $@->message, __x(
    '{color} is not a valid ANSI color', color => 'BLUELOLZ'
), 'Invalid color error message should be correct';

##############################################################################
# Test execute().
my $emock = Test::MockModule->new('App::Sqitch::Engine::sqlite');
$emock->mock(destination => 'flipr');

my $mock_target = Test::MockModule->new('App::Sqitch::Target');
my ($target_name_arg, $orig_meth);
$target_name_arg = '_blah';
$mock_target->mock(new => sub {
    my $self = shift;
    my %p = @_;
    $target_name_arg = $p{name};
    $self->$orig_meth(@_);
});
$orig_meth = $mock_target->original('new');

# First test for uninitialized DB.
my $init = 0;
$emock->mock(initialized => sub { $init });
throws_ok { $log->execute } 'App::Sqitch::X',
    'Should get exception for unititialied db';
is $@->ident, 'log', 'Uninit db error ident should be "log"';
is $@->exitval, 1, 'Uninit db exit val should be 1';
is $@->message, __x(
    'Database {db} has not been initialized for Sqitch',
    db => 'db:sqlite:',
), 'Uninit db error message should be correct';
is $target_name_arg, undef, 'Should have passed undef to Target';

# Next, test for no events.
$init = 1;
$target_name_arg = '_blah';
my @events;
my $iter = sub { shift @events };
my $search_args;
$emock->mock(search_events => sub {
    shift;
    $search_args = [@_];
    return $iter;
});
$log = $CLASS->new(sqitch => $sqitch);
throws_ok { $log->execute } 'App::Sqitch::X',
    'Should get error for empty event table';
is $@->ident, 'log', 'no events error ident should be "log"';
is $@->exitval, 1, 'no events exit val should be 1';
is $@->message, __x(
    'No events logged for {db}',
    db => 'flipr',
), 'no events error message should be correct';
is_deeply $search_args, [limit => 1],
    'Search should have been limited to one row';
is $target_name_arg, undef, 'Should have passed undef to Target again';

# Okay, let's add some events.
push @events => {}, $event;
$target_name_arg = '_blah';
$log = $CLASS->new(sqitch => $sqitch);
ok $log->execute, 'Execute log';
is $target_name_arg, undef, 'Should have passed undef to Target once more';
is_deeply $search_args, [
    event     => undef,
    change    => undef,
    project   => undef,
    committer => undef,
    limit     => undef,
    offset    => undef,
    direction => 'DESC'
], 'The proper args should have been passed to search_events';

is_deeply +MockOutput->get_page, [
    [__x 'On database {db}', db => 'flipr'],
    [ $log->formatter->format( $log->format, $event ) ],
], 'The change should have been paged';

# Make sure a passed target is processed.
push @events => {}, $event;
$target_name_arg = '_blah';
ok $log->execute('db:sqlite:whatever.db'), 'Execute with target arg';
is $target_name_arg, 'db:sqlite:whatever.db',
    'Target name should have been passed to Target';
is_deeply $search_args, [
    event     => undef,
    change    => undef,
    project   => undef,
    committer => undef,
    limit     => undef,
    offset    => undef,
    direction => 'DESC'
], 'The proper args should have been passed to search_events';

is_deeply +MockOutput->get_page, [
    [__x 'On database {db}', db => 'flipr'],
    [ $log->formatter->format( $log->format, $event ) ],
], 'The change should have been paged';

# Make sure we can pass a plan file.
push @events => {}, $event;
$target_name_arg = '_blah';
ok $log->execute($plan_file), 'Execute with plan file arg';
is $target_name_arg, 'db:sqlite:',
    'Default engine target should have been passed to Target';
is_deeply $search_args, [
    event     => undef,
    change    => undef,
    project   => undef,
    committer => undef,
    limit     => undef,
    offset    => undef,
    direction => 'DESC'
], 'The proper args should have been passed to search_events';

is_deeply +MockOutput->get_page, [
    [__x 'On database {db}', db => 'flipr'],
    [ $log->formatter->format( $log->format, $event ) ],
], 'The change should have been paged';



# Set attributes and add more events.
my $event2 = {
    event           => 'revert',
    change_id       => '84584584359345',
    change          => 'barf',
    tags            => [],
    committer_name  => 'theory',
    committer_email => 'theory@example.com',
    committed_at    => $cdt,
    note            => 'Oh man this was a bad idea',
};
push @events => {}, $event, $event2;
isa_ok $log = $CLASS->new(
    sqitch            => $sqitch,
    target            => 'db:sqlite:foo.db',
    event             => [qw(revert fail)],
    change_pattern    => '.+',
    project_pattern   => '.+',
    committer_pattern => '.+',
    max_count         => 10,
    skip              => 5,
    reverse           => 1,
), $CLASS, 'log with attributes';

$target_name_arg = '_blah';
ok $log->execute, 'Execute log with attributes';
is $target_name_arg, $log->target, 'Should have passed target name to Target';
is_deeply $search_args, [
    event     => [qw(revert fail)],
    change    => '.+',
    project   => '.+',
    committer => '.+',
    limit     => 10,
    offset    => 5,
    direction => 'ASC'
], 'All params should have been passed to search_events';

is_deeply +MockOutput->get_page, [
    [__x 'On database {db}', db => 'flipr'],
    [ $log->formatter->format( $log->format, $event ) ],
    [ $log->formatter->format( $log->format, $event2 ) ],
], 'Both changes should have been paged';

# Make sure we get a warning when both the option and the arg are specified.
push @events => {}, $event;
ok $log->execute('pg'), 'Execute log with attributes';
is $target_name_arg, 'db:pg:', 'Should have passed enginetarget to Target';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => $log->target,
)]], 'Should have got warning for two targets';

# Make sure we catch bad format codes.
isa_ok $log = $CLASS->new(
    sqitch => $sqitch,
    format => '%Z',
), $CLASS, 'log with bad format';

push @events, {}, $event;
$target_name_arg = '_blah';
throws_ok { $log->execute } 'App::Sqitch::X',
    'Should get an exception for a bad format code';
is $@->ident, 'format',
    'bad format code format error ident should be "format"';
is $@->message, __x(
    'Unknown format code "{code}"', code => 'Z',
), 'bad format code format error message should be correct';
is $target_name_arg, $log->target, 'Should have passed target name to Target';
