#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 35;
#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use Test::Exception;
use lib 't/lib';
use MockCommand;

my $CLASS = 'App::Sqitch::Command::add_step';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $add_step = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'add-step',
    config  => $config,
}), $CLASS, 'add_step command';

can_ok $CLASS, qw(
    options
    requires
    conflicts
    variables
    template_directory
    with_deploy
    with_revert
    with_test
    deploy_template
    revert_template
    test_template
    configure
    _find
);

is_deeply [$CLASS->options], [qw(
    requires|r=s
    conflicts|c=s
    set|s=s%
    template-directory=s
    deploy-template=s
    revert-template=s
    test-template=s
    deploy!
    revert!
    test!
)], 'Options should be set up';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {
    requires  => [],
    conflicts => [],
}, 'Should have default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}), {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
}, 'Should have get requires and conflicts options';

is_deeply $CLASS->configure($config, { template_directory => 't' }), {
    requires  => [],
    conflicts => [],
    template_directory => Path::Class::dir('t'),
}, 'Should set up template directory option';

is_deeply $CLASS->configure($config, {
    deploy => 1,
    revert => 1,
    test   => 0,
    deploy_template => 'templates/deploy.tmpl',
    revert_template => 'templates/revert.tmpl',
    test_template => 'templates/test.tmpl',
}), {
    requires  => [],
    conflicts => [],
    with_deploy => 1,
    with_revert => 1,
    with_test => 0,
    deploy_template => Path::Class::file('templates/deploy.tmpl'),
    revert_template => Path::Class::file('templates/revert.tmpl'),
    test_template => Path::Class::file('templates/test.tmpl'),
}, 'Should have get template options';

# Test variable configuration.
CONFIG: {
    local $ENV{SQITCH_CONFIG} = File::Spec->catfile(qw(t add_step.conf));
    my $config = App::Sqitch::Config->new;
    is_deeply $CLASS->configure($config, {}), {
        requires  => [],
        conflicts => [],
    }, 'Variables should by default not be loaded from config';

    is_deeply $CLASS->configure($config, {set => { yo => 'dawg' }}), {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'bar',
            baz => [qw(hi there you)],
            yo  => 'dawg',
        },
    }, '--set should be merged with config variables';

    is_deeply $CLASS->configure($config, {set => { foo => 'ick' }}), {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'ick',
            baz => [qw(hi there you)],
        },
    }, '--set should be override config variables';
}

##############################################################################
# Test attributes.
is_deeply $add_step->requires, [], 'Requires should be an arrayref';
is_deeply $add_step->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $add_step->variables, {}, 'Varibles should be a hashref';
is $add_step->template_directory, undef, 'Default dir should be undef';

for my $script (qw(deploy revert test)) {
    my $with = "with_$script";
    ok $add_step->$with, "$with should be true by default";
    my $tmpl = "$script\_template";
    throws_ok { $add_step->$tmpl } qr/FAIL/, "Should die on $tmpl";
    is_deeply +MockCommand->get_fail, [["Cannot find $script template"]],
        "Should get $tmpl failure message";
}

# Point to a valid template directory.
ok $add_step = $CLASS->new(
    sqitch => $sqitch,
    template_directory => Path::Class::dir('templates')
), 'Create add_step with template_directory';

for my $script (qw(deploy revert test)) {
    my $tmpl = "$script\_template";
    is $add_step->$tmpl, Path::Class::file('templates', "$script.tmpl"),
        "Should find $script in templates directory";
}

##############################################################################
# Test find().
is $add_step->_find('deploy'), Path::Class::file('templates', "deploy.tmpl"),
    '_find should work with template_directory';

ok $add_step = $CLASS->new(sqitch => $sqitch),
    'Create add_step with no template directory';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock(system_dir => Path::Class::dir('nonexistent'));
    $config_mock->mock(user_dir => Path::Class::dir('.'));
    is $add_step->_find('deploy'), Path::Class::file('templates', "deploy.tmpl"),
        '_find should work with user_dir from Config';

    $config_mock->unmock('user_dir');
    throws_ok { $add_step->_find('test') } qr/FAIL/,
        "Should die trying to find template";
    is_deeply +MockCommand->get_fail, [["Cannot find test template"]],
        "Should get unfound test template message";

    $config_mock->mock(system_dir => Path::Class::dir('.'));
    is $add_step->_find('deploy'), Path::Class::file('templates', "deploy.tmpl"),
        '_find should work with system_dir from Config';
}
