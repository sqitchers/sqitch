#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Test::MockModule;
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::verify';
require_ok $CLASS or die;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    from_change
    to_change
    variables
);

is_deeply [$CLASS->options], [qw(
    target|t=s
    from-change|from=s
    to-change|to=s
    from-target=s
    to-target=s
    set|s=s%
)], 'Options should be correct';

my $sqitch = App::Sqitch->new(
    options => {
        engine    => 'sqlite',
        plan_file => file(qw(t sql sqitch.plan))->stringify,
        top_dir   => dir(qw(t sql))->stringify,
    },
);
my $config = $sqitch->config;

# Test configure().
is_deeply $CLASS->configure($config, {}), {
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    from_change => 'foo',
    to_change   => 'bar',
    set  => { foo => 'bar' },
}), {
    from_change => 'foo',
    to_change   => 'bar',
    variables   => { foo => 'bar' },
}, 'Should have changes and variables from options';

CONFIG: {
    my $mock_config = Test::MockModule->new(ref $config);
    my %config_vals;
    $mock_config->mock(get => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{key} };
    });
    $mock_config->mock(get_section => sub {
        my ($self, %p) = @_;
        return $config_vals{ $p{section} };
    });
    %config_vals = (
        'verify.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {},
        'Should have no config if no options';

    # Try merging.
    is_deeply $CLASS->configure($config, {
        to_change => 'whu',
        set       => { foo => 'yo', yo => 'stellar' },
    }), {
        to_change => 'whu',
        variables => { foo => 'yo', yo => 'stellar', hi => 21 },
    }, 'Should have merged variables';

    isa_ok my $verify = $CLASS->new(sqitch => $sqitch), $CLASS;
    is_deeply $verify->variables, { foo => 'bar', hi => 21 },
        'Should pick up variables from configuration';
}

##############################################################################
# Test accessors.
isa_ok my $verify = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new status with target';
is $verify->target, 'foo', 'Should have target "foo"';

isa_ok $verify = $CLASS->new(sqitch => $sqitch), $CLASS;
is $verify->target, undef, 'Default target should be undef';
is $verify->from_change, undef, 'from_change should be undef';
is $verify->to_change, undef, 'to_change should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @args;
$mock_engine->mock(verify => sub { shift; @args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; @vars = @_ });

ok $verify->execute, 'Execute with nothing.';
is_deeply \@args, [undef, undef],
    'Two undefs should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

ok $verify->execute('@alpha'), 'Execute from "@alpha"';
is_deeply \@args, ['@alpha', undef],
    '"@alpha" and undef should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should again have no warnings';

ok $verify->execute('@alpha', '@beta'), 'Execute from "@alpha" to "@beta"';
is_deeply \@args, ['@alpha', '@beta'],
    '"@alpha" and "@beat" should be passed to the engine';
is_deeply +MockOutput->get_warn, [], 'Should still have no warnings';

isa_ok $verify = $CLASS->new(
    sqitch      => $sqitch,
    from_change => 'foo',
    to_change   => 'bar',
    variables => { foo => 'bar', one => 1 },
), $CLASS, 'Object with from, to, and variables';

ok $verify->execute, 'Execute again';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Still should have no warnings';

# Pass and specify changes.
ok $verify->execute('roles', 'widgets'), 'Execute with command-line args';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many changes specified; verifying from "{from}" to "{to}"',
    from => 'foo',
    to   => 'bar',
)]], 'Should have warning about which roles are used';

# Pass a target.
my $target = 'db:pg:';
my $mock_cmd = Test::MockModule->new(ref $verify);
my ($target_name_arg, $orig_meth);
$mock_cmd->mock(parse_args => sub {
    my $self = shift;
    my %p = @_;
    my @ret = $self->$orig_meth(@_);
    $target_name_arg = $ret[0][0]->name;
    $ret[0][0] = $self->default_target;
    return @ret;
});
$orig_meth = $mock_cmd->original('parse_args');

ok $verify->execute($target), 'Execute with target arg';
is $target_name_arg, $target, 'The target should have been passed to the engine';
is_deeply \@args, ['foo', 'bar'],
    '"foo" and "bar" should be passed to the engine';
is_deeply {@vars}, { foo => 'bar', one => 1 },
    'Vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should once again have no warnings';

# Pass a --target option.
isa_ok $verify = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS, 'Object with target';
$target_name_arg = undef;
@vars = ();
ok $verify->execute, 'Execute with no args';
is $target_name_arg, $target, 'The target option should have been passed to the engine';
is_deeply \@args, [undef, undef], 'Undefs should be passed to the engine';
is_deeply {@vars}, {}, 'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should once again have no warnings';

# Pass a target, get a warning.
ok $verify->execute('db:sqlite:', 'roles', 'widgets'),
    'Execute with two targegs and two changes';
is $target_name_arg, $target, 'The target option should have been passed to the engine';
is_deeply \@args, ['roles', 'widgets'],
    'The two changes should be passed to the engine';
is_deeply {@vars}, {}, 'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => $verify->default_target->name,
)]], 'Should have warning about too many targets';

# Make sure we get an exception for unknown args.
throws_ok { $verify->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'verify', 'Unknow arg ident should be "verify"';
is $@->message, __x(
    'Unknown argument "{arg}"',
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $verify->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'verify', 'Unknow args ident should be "verify"';
is $@->message, __x(
    'Unknown arguments: {arg}',
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

done_testing;
