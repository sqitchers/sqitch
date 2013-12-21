#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 51;
use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::Exception;
use Test::NoWarnings;
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS = 'App::Sqitch::Command::target';

##############################################################################
# Load a target command and test the basics.
chdir 't';
$ENV{SQITCH_CONFIG} = 'target.conf';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $cmd = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'target',
    config  => $config,
}), $CLASS, 'Target command';

can_ok $cmd, qw(
    options
    configure
    execute
    list
    add
    update
    remove
    rename
    rm
    show
);

is_deeply [$CLASS->options], [qw(
    uri|set-uri|u=s
    registry|set-registry|r=s
    client|set-client|c=s
    v|verbose+
)], 'Options should be correct';

# Check default attribute values.
is $cmd->verbose,  0,     'Default verbosity should be 0';
is $cmd->uri,      undef, 'Default URI should be undef';
is $cmd->registry, undef, 'Default registry should be undef';
is $cmd->client,   undef, 'Default client should be undef';

# Make sure configure ignores config file.
is_deeply $CLASS->configure({ foo => 'bar'}, { hi => 'there' }),
    { hi => 'there' },
    'configure() should ignore config file';

# Make sure configure() turns the URI into a URI::db object.
ok my $opt = $CLASS->configure({}, { uri => 'pg:'}), 'Get config';
isa_ok $opt->{uri}, 'URI::db', 'URI option';
is $opt->{uri}->as_string, 'db:pg:', 'URI should look like a DB URI';

##############################################################################
# Test list().
ok $cmd->list, 'Run list()';
is_deeply +MockOutput->get_emit, [['dev'], ['prod'], ['qa']],
    'The list of targets should have been output';

# Make it verbose.
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch, verbose => 1 }),
    $CLASS, 'Verbose target';
ok $cmd->list, 'Run verbose list()';
is_deeply +MockOutput->get_emit, [
    ["dev\tdb:pg:widgets"],
    ["prod\tdb:pg://prod.example.us/pr_widgets"],
    ["qa\tdb:pg://qa.example.com/qa_widgets"]
], 'The list of targets and their URIs should have been output';

##############################################################################
# Test _name_uri().
NAMEURI: {
    # Test handling of no name.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $cmd->_name_uri } qr/USAGE/,
        'No name arg to add() should yield usage';
    is_deeply \@args, [$cmd], 'No args should be passed to usage';

    # Test handling of no URI.
    @args = ();
    throws_ok { $cmd->_name_uri('foo') } qr/USAGE/,
        'No URI arg or option should yield usage';
    is_deeply \@args, [$cmd], 'Usage should have been called';

    # Try both URI option and arg.
    isa_ok my $cmd = $CLASS->new({
        sqitch => $sqitch, uri => URI::db->new('db:pg:')
    }), $CLASS, 'Target with URI option';
    is_deeply [$cmd->_name_uri('foo', 'db:pg:foo')],
        ['foo', URI->new('db:pg:')],
        'Should get URI option when also have URI arg';
    is_deeply +MockOutput->get_warn, [[__x(
        'Both the --uri option and the uri argument passed; using {option}',
        option => 'db:pg:',
    )]], 'Should get warning for two URIs';

    # Should be okay if the dupes are the same.
    is_deeply [$cmd->_name_uri('foo', 'db:pg:')],
        ['foo', URI->new('db:pg:')],
        'Should get URI option when have dupe URIs';
    is_deeply +MockOutput->get_warn, [],
        'Should have no warnings on dupe URI';

    # Should be fine if just have the option.
    is_deeply [$cmd->_name_uri('foo')], ['foo', URI->new('db:pg:')],
        'Should get URI option when have just --uri';
    is_deeply +MockOutput->get_warn, [],
        'Should have no warnings on --uri only';
}

##############################################################################
# Test execute().
isa_ok $cmd = $CLASS->new({ sqitch => $sqitch }), $CLASS, 'Simple target';
for my $spec (
    [ undef,  'list'   ],
    [ 'list'           ],
    [ 'add'            ],
    [ 'update'         ],
    [ 'remove'         ],
    [ 'rm',   'remove' ],
    [ 'rename'         ],
    [ 'show'           ],
) {
    my ($arg, $meth) = @{ $spec };
    $meth //= $arg;
    my $mocker = Test::MockModule->new($CLASS);
    my @args;
    $mocker->mock($meth => sub { @args = @_ });
    ok $cmd->execute($spec->[0]), "Execute " . ($spec->[0] // 'undef');
    is_deeply \@args, [$cmd], "$meth() should have been called";

    # Make sure args are passed.
    ok $cmd->execute($spec->[0], qw(foo bar)),
        "Execute " . ($spec->[0] // 'undef') . ' with args';
    is_deeply \@args, [$cmd, qw(foo bar)],
        "$meth() should have been passed args";
}

# Make sure an invalid action dies.
throws_ok { $cmd->execute('nonexistent') } 'App::Sqitch::X',
    'Should get an exception for a nonexistent action';
is $@->ident, 'target', 'Nonexistent action error ident should be "target"';
is $@->message, __x(
    'Unknown action "{action}"',
    action => 'nonexistent',
), 'Nonexistent action error message should be correct';
