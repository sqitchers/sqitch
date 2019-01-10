#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 25;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Test::NoWarnings;
use Test::Exception;
use Test::Warn;
use Test::MockModule;
use Path::Class;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::upgrade';
require_ok $CLASS;

my $config = TestConfig->new(
    'core.engine'  => 'sqlite',
    'core.top_dir' => dir->new('test-upgrade')->stringify,
);
ok my $sqitch = App::Sqitch->new(config => $config), 'Load a sqitch object';
isa_ok my $upgrade = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'upgrade',
    config  => $config,
}), $CLASS, 'upgrade command';

can_ok $upgrade, qw(
    target
    options
    execute
    configure
    does
);

ok $CLASS->does("App::Sqitch::Role::ConnectingCommand"),
    "$CLASS does ConnectingCommand";

is_deeply [ $CLASS->options ], [qw(
    target|t=s
    registry=s
    client|db-client=s
    db-name|d=s
    db-user|db-username|u=s
    db-host|h=s
    db-port|p=i
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';

# Start with the engine up-to-date.
my $engine_mocker = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my $registry_version = App::Sqitch::Engine->registry_release;
my $upgrade_called = 0;
$engine_mocker->mock(registry_version => sub { $registry_version });
$engine_mocker->mock(upgrade_registry => sub { $upgrade_called = 1 });

ok $upgrade->execute, 'Execute upgrade';
ok !$upgrade_called, 'Upgrade should not have been called';
is_deeply +MockOutput->get_info, [[__x(
    'Registry {registry} is up-to-date at version {version}',
    registry => 'db:sqlite:',
    version  => App::Sqitch::Engine->registry_release,
)]], 'Should get output for up-to-date registry';

# Pass in a different target.
ok $upgrade->execute('db:sqlite:foo.db'), 'Execute upgrade with target';
ok !$upgrade_called, 'Upgrade should again not have been called';
is_deeply +MockOutput->get_info, [[__x(
    'Registry {registry} is up-to-date at version {version}',
    registry => 'db:sqlite:sqitch.db',
    version  => App::Sqitch::Engine->registry_release,
)]], 'Should get output for up-to-date registry with target';

# Pass in an engine.
ok $upgrade->execute('sqlite'), 'Execute upgrade with engine';
ok !$upgrade_called, 'Upgrade should again not have been called';
is_deeply +MockOutput->get_info, [[__x(
    'Registry {registry} is up-to-date at version {version}',
    registry => 'db:sqlite:',
    version  => App::Sqitch::Engine->registry_release,
)]], 'Should get output for up-to-date registry with target';

# Specify a target as an option.
isa_ok $upgrade = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'upgrade',
    config  => $config,
    args    => [qw(--target db:sqlite:my.sqlite)],
}), $CLASS, 'upgrade command with target';

ok $upgrade->execute, 'Execute upgrade with target option';
ok !$upgrade_called, 'Upgrade should still not have been called';
is_deeply +MockOutput->get_info, [[__x(
    'Registry {registry} is up-to-date at version {version}',
    registry => 'db:sqlite:sqitch.sqlite',
    version  => App::Sqitch::Engine->registry_release,
)]], 'Should get output for up-to-date registry with target option';

# Now make it upgrade.
$registry_version = 0.1;
ok $upgrade->execute, 'Execute upgrade with out-of-date registry';
ok $upgrade_called, 'Upgrade should now have been called';
is_deeply +MockOutput->get_info, [[__x(
    'Upgrading registry {registry} to version {version}',
    registry => 'db:sqlite:sqitch.sqlite',
    version  => App::Sqitch::Engine->registry_release,
)]], 'Should get output for the upgrade';
