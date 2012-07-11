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
