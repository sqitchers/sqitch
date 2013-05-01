#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 215;
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
use Encode;

my $CLASS = 'App::Sqitch::Command::plan';
require_ok $CLASS;

ok my $sqitch = App::Sqitch->new(
    top_dir => Path::Class::Dir->new('sql'),
    _engine => 'sqlite',
    plan_file => file(qw(t sql sqitch.plan)),
), 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'plan',
    config  => $config,
}), $CLASS, 'plan command';

can_ok $cmd, qw(
    change_pattern
    planner_pattern
    max_count
    skip
    reverse
    format
    options
    execute
    configure
);

is_deeply [$CLASS->options], [qw(
    event=s
    change-pattern|change=s
    planner-pattern|planner=s
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
    'Invalid date format error ident should be "plan"';
is $@->message, __x(
    'Unknown date format "{format}"',
    format => 'non',
), 'Invalid date format error message should be correct';

# Test format validation.
$cmock->mock( get => sub {
    my ($self, %p) = @_;
    return 'nonesuch' if $p{key} eq 'plan.format';
    return undef;
});
throws_ok { $CLASS->configure($config, {}), {} } 'App::Sqitch::X',
    'Should get error for invalid format in config';
is $@->ident, 'plan',
    'Invalid format error ident should be "plan"';
is $@->message, __x(
    'Unknown plan format "{format}"',
    format => 'nonesuch',
), 'Invalid format error message should be correct';
$cmock->unmock_all;

throws_ok { $CLASS->configure($config, { format => 'non'}), {} }
    'App::Sqitch::X',
    'Should get error for invalid format in optsions';
is $@->ident, 'plan',
    'Invalid format error ident should be "plan"';
is $@->message, __x(
    'Unknown plan format "{format}"',
    format => 'non',
), 'Invalid format error message should be correct';

# Test color configuration.
$configured = $CLASS->configure( $config, { no_color => 1 } );
is $configured->{formatter}->color, 'never',
    'Configuration should respect --no-color, setting "never"';

# Test oneline configuration.
$configured = $CLASS->configure( $config, { oneline => 1 });
is $configured->{format}, '%{:event}C%h %l%{reset}C %n%{cyan}C%t%{reset}C',
    '--oneline should set format';
is $configured->{formatter}{abbrev}, 6, '--oneline should set abbrev to 6';

$configured = $CLASS->configure( $config, { oneline => 1, format => 'format:foo', abbrev => 5 });
is $configured->{format}, 'foo', '--oneline should not override --format';
is $configured->{formatter}{abbrev}, 5, '--oneline should not overrride --abbrev';

my $config_color = 'auto';
$cmock->mock( get => sub {
    my ($self, %p) = @_;
    return $config_color if $p{key} eq 'plan.color';
    return undef;
});

my $cmd_config = {};
$cmock->mock( get_section => sub { $cmd_config } );

$configured = $CLASS->configure( $config, { no_color => 1 } );

is $configured->{formatter}->color, 'never',
    'Configuration should respect --no-color even when configure is set';

NEVER: {
    $config_color = 'never';
    $cmd_config = { color => $config_color };
    my $configured = $CLASS->configure( $config, $cmd_config );
    is $configured->{formatter}->color, 'never',
        'Configuration should respect color option';

    # Try it with config.
    $cmd_config = { color => $config_color };
    $configured = $CLASS->configure( $config, {} );
    is $configured->{formatter}->color, 'never',
        'Configuration should respect color config';
}

ALWAYS: {
    $config_color = 'always';
    $cmd_config = { color => $config_color };
    my $configured = $CLASS->configure( $config, $cmd_config );
    is_deeply $configured->{formatter}->color, 'always',
        'Configuration should respect color option';

    # Try it with config.
    $cmd_config = { color => $config_color };
    $configured = $CLASS->configure( $config, {} );
    is_deeply $configured->{formatter}->color, 'always',
        'Configuration should respect color config';
}

AUTO: {
    $config_color = 'auto';
    $cmd_config = { color => $config_color };
    for my $enabled (0, 1) {
        my $configured = $CLASS->configure( $config, $cmd_config );
        is_deeply $configured->{formatter}->color, 'auto',
            'Configuration should respect color option';

        # Try it with config.
        $cmd_config = { color => $config_color };
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
my $change = {
    event           => 'deploy',
    project         => 'planit',
    change_id       => '000011112222333444',
    change          => 'lolz',
    tags            => [ '@beta', '@gamma' ],
    planner_name    => 'damian',
    planner_email   => 'damian@example.com',
    planned_at      => $pdt,
    note            => "For the LOLZ.\n\nYou know, funny stuff and cute kittens, right?",
    requires        => [qw(foo bar)],
    conflicts       => []
};

my $piso = $pdt->as_string( format => 'iso' );
my $praw = $pdt->as_string( format => 'raw' );
for my $spec (
    [ raw => "deploy 000011112222333444 (\@beta, \@gamma)\n"
        . "name      lolz\n"
        . "project   planit\n"
        . "requires  foo, bar\n"
        . "planner   damian <damian\@example.com>\n"
        . "planned   $praw\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ full =>  __('Deploy') . " 000011112222333444 (\@beta, \@gamma)\n"
        . __('Name:     ') . " lolz\n"
        . __('Project:  ') . " planit\n"
        . __('Requires: ') . " foo, bar\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n"
        . __('Planned:  ') . " __PDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ long =>  __('Deploy') . " 000011112222333444 (\@beta, \@gamma)\n"
        . __('Name:     ') . " lolz\n"
        . __('Project:  ') . " planit\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ medium =>  __('Deploy') . " 000011112222333444\n"
        . __('Name:     ') . " lolz\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n"
        . __('Date:     ') . " __PDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ short =>  __('Deploy') . " 000011112222333444\n"
        . __('Name:     ') . " lolz\n"
        . __('Planner:  ') . " damian <damian\@example.com>\n\n"
        . "    For the LOLZ.\n",
    ],
    [ oneline => '000011112222333444 ' . __('deploy') . ' lolz @beta, @gamma' ],
) {
    local $ENV{ANSI_COLORS_DISABLED} = 1;
    my $configured = $CLASS->configure( $config, { format => $spec->[0] } );
    my $format = $configured->{format};
    ok my $cmd = $CLASS->new( sqitch => $sqitch, %{ $configured } ),
        qq{Instantiate with format "$spec->[0]"};
    (my $exp = $spec->[1]) =~ s/__PDATE__/$piso/;
    is $cmd->formatter->format( $cmd->format, $change ), $exp,
        qq{Format "$spec->[0]" should output correctly};

    if ($spec->[1] =~ /__PDATE__/) {
        # Test different date formats.
        for my $date_format (qw(rfc long medium)) {
            ok my $cmd = $CLASS->new(
                sqitch => $sqitch,
                format => $format,
                formatter => App::Sqitch::ItemFormatter->new(date_format => $date_format),
            ), qq{Instantiate with format "$spec->[0]" and date format "$date_format"};
            my $date = $pdt->as_string( format => $date_format );
            (my $exp = $spec->[1]) =~ s/__PDATE__/$date/;
            is $cmd->formatter->format( $cmd->format, $change ), $exp,
                qq{Format "$spec->[0]" and date format "$date_format" should output correctly};
        }
    }

    if ($spec->[1] =~ s/\s+[(]?[@]beta,\s+[@]gamma[)]?//) {
        # Test without tags.
        local $change->{tags} = [];
        (my $exp = $spec->[1]) =~ s/__PDATE__/$piso/;
        is $cmd->formatter->format( $cmd->format, $change ), $exp,
            qq{Format "$spec->[0]" should output correctly without tags};
    }
}

###############################################################################
# Test all formatting characters.
my $local_pdt = $pdt->clone;
$local_pdt->set_time_zone('local');

if ($^O eq 'MSWin32') {
    require Win32::Locale;
    $local_pdt->set( locale => Win32::Locale::get_locale() );
} else {
    require POSIX;
    $local_pdt->set( locale =>POSIX::setlocale( POSIX::LC_TIME() ) );
}

my $formatter = $cmd->formatter;
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
    ['%{planner}_',   {}, __ 'Planner:  ' ],
    ['%{by}_',        {}, __ 'By:       ' ],
    ['%{date}_',      {}, __ 'Date:     ' ],
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

    ['%{change}a',    $change, "change    $change->{change}\n" ],
    ['%{change_id}a', $change, "change_id $change->{change_id}\n" ],
    ['%{event}a',     $change, "event     $change->{event}\n" ],
    ['%{tags}a',      $change, 'tags      ' . join(', ', @{ $change->{tags} }) . "\n" ],
    ['%{requires}a',  $change, 'requires  ' . join(', ', @{ $change->{requires} }) . "\n" ],
    ['%{conflicts}a', $change, '' ],
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

ok $cmd = $CLASS->new(
    sqitch    => $sqitch,
    formatter => App::Sqitch::ItemFormatter->new(abbrev => 4)
), 'Instantiate with abbrev => 4';
is $cmd->formatter->format( '%h', { change_id => '123456789' } ),
    '1234', '%h should respect abbrev';
is $cmd->formatter->format( '%H', { change_id => '123456789' } ),
    '123456789', '%H should not respect abbrev';

ok $cmd = $CLASS->new(
    sqitch    => $sqitch,
    formatter => App::Sqitch::ItemFormatter->new(date_format => 'rfc')
), 'Instantiate with date_format => "rfc"';
is $cmd->formatter->format( '%{date}p', { planned_at => $cdt } ),
    $cdt->as_string( format => 'rfc' ),
    '%{date}p should respect the date_format attribute';
is $cmd->formatter->format( '%{d:iso}p', { planned_at => $cdt } ),
    $cdt->as_string( format => 'iso' ),
    '%{iso}p should override the date_format attribute';

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
my $cyan   = color('cyan')   . ' %s' . color('reset');
$change->{conflicts} = [qw(dr_evil)];
for my $spec (
    [ full => sprintf($green, __ ('Deploy') . ' 000011112222333444')
        . " (\@beta, \@gamma)\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Project:  ') . " planit\n"
        . __ ('Requires: ') . " foo, bar\n"
        . __ ('Conflicts:') . " dr_evil\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n"
        . __ ('Planned:  ') . " __PDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ long => sprintf($green, __ ('Deploy') . ' 000011112222333444')
        . " (\@beta, \@gamma)\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Project:  ') . " planit\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ medium => sprintf($green, __ ('Deploy') . ' 000011112222333444') . "\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n"
        . __ ('Date:     ') . " __PDATE__\n\n"
        . "    For the LOLZ.\n    \n    You know, funny stuff and cute kittens, right?\n"
    ],
    [ short => sprintf($green, __ ('Deploy') . ' 000011112222333444') . "\n"
        . __ ('Name:     ') . " lolz\n"
        . __ ('Planner:  ') . " damian <damian\@example.com>\n\n"
        . "    For the LOLZ.\n",
    ],
    [ oneline => sprintf "$green %s$cyan", '000011112222333444' . ' '
        . __('deploy'), 'lolz', '@beta, @gamma',
    ],
) {
    my $format = $CLASS->configure( $config, { format => $spec->[0] } )->{format};
    ok my $cmd = $CLASS->new( sqitch => $sqitch, format => $format ),
        qq{Instantiate with format "$spec->[0]" again};
    (my $exp = $spec->[1]) =~ s/__PDATE__/$piso/;
    is $cmd->formatter->format( $cmd->format, $change ), $exp,
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
my $pmock = Test::MockModule->new('App::Sqitch::Plan');

# First, test for no changes.
$pmock->mock(count => 0);

throws_ok { $cmd->execute } 'App::Sqitch::X',
    'Should get error for no changes';
is $@->ident, 'plan', 'no changes error ident should be "plan"';
is $@->exitval, 1, 'no changes exit val should be 1';
is $@->message, __x(
    'No changes in {file}',
    file => $sqitch->plan_file
), 'no changes error message should be correct';
$pmock->unmock('count');

# Okay, let's see some changes.
my @changes;
my $iter = sub { shift @changes };
my $search_args;
$pmock->mock(search_changes => sub {
    shift;
    $search_args = [@_];
    return $iter;
});

$change = $sqitch->plan->change_at(0);
push @changes => $change;
ok $cmd->execute, 'Execute plan';
is_deeply $search_args, [
    operation => undef,
    name      => undef,
    planner   => undef,
    limit     => undef,
    offset    => undef,
    direction => 'ASC'
], 'The proper args should have been passed to search_events';

my $fmt_params = {
    event         => $change->is_deploy ? 'deploy' : 'revert',
    project       => $change->project,
    change_id     => $change->id,
    change        => $change->name,
    note          => $change->note,
    tags          => [ map { $_->format_name } $change->tags ],
    requires      => [ map { $_->as_string } $change->requires ],
    conflicts     => [ map { $_->as_string } $change->conflicts ],
    planned_at    => $change->timestamp,
    planner_name  => $change->planner_name,
    planner_email => $change->planner_email,
};
is_deeply +MockOutput->get_page, [
    ['# ', __x 'Project: {project}', project => $sqitch->plan->project ],
    ['# ', __x 'File:    {file}', file => $sqitch->plan_file ],
    [''],
    [ $cmd->formatter->format( $cmd->format, $fmt_params ) ],
], 'The event should have been paged';

# Set attributes and add more events.
my $change2 = $sqitch->plan->change_at(1);
push @changes => $change, $change2;
isa_ok $cmd = $CLASS->new(
    sqitch            => $sqitch,
    event             => 'deploy',
    change_pattern    => '.+',
    project_pattern   => '.+',
    planner_pattern   => '.+',
    max_count         => 10,
    skip              => 5,
    reverse           => 1,
), $CLASS, 'plan with attributes';

ok $cmd->execute, 'Execute plan with attributes';
is_deeply $search_args, [
    operation => 'deploy',
    name      => '.+',
    planner   => '.+',
    limit     => 10,
    offset    => 5,
    direction => 'DESC'
], 'All params should have been passed to search_events';

my $fmt_params2 = {
    event         => $change2->is_deploy ? 'deploy' : 'revert',
    project       => $change2->project,
    change_id     => $change2->id,
    change        => $change2->name,
    note          => $change2->note,
    tags          => [ map { $_->format_name } $change2->tags ],
    requires      => [ map { $_->as_string } $change2->requires ],
    conflicts     => [ map { $_->as_string } $change2->conflicts ],
    planned_at    => $change2->timestamp,
    planner_name  => $change2->planner_name,
    planner_email => $change2->planner_email,
};

is_deeply +MockOutput->get_page, [
    ['# ', __x 'Project: {project}', project => $sqitch->plan->project ],
    ['# ', __x 'File:    {file}', file => $sqitch->plan_file ],
    [''],
    [ $cmd->formatter->format( $cmd->format, $fmt_params  ) ],
    [ $cmd->formatter->format( $cmd->format, $fmt_params2 ) ],
], 'Both events should have been paged';

# Make sure we catch bad format codes.
isa_ok $cmd = $CLASS->new(
    sqitch => $sqitch,
    format => '%Z',
), $CLASS, 'plan with bad format';

push @changes, $change;
throws_ok { $cmd->execute } 'App::Sqitch::X',
    'Should get an exception for a bad format code';
is $@->ident, 'format',
    'bad format code format error ident should be "format"';
is $@->message, __x(
    'Unknown format code "{code}"', code => 'Z',
), 'bad format code format error message should be correct';
