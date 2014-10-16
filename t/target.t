#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
#use Test::More tests => 142;
use Test::More 'no_plan';
use App::Sqitch;
use Path::Class qw(dir);
use Test::Exception;
use Test::MockModule;
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use MockOutput;

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::Target';
    use_ok $CLASS or die;
}

##############################################################################
# Load a target and test the basics.
ok my $sqitch = App::Sqitch->new(options => { engine => 'sqlite'}),
    'Load a sqitch sqitch object';
isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS;
can_ok $target, qw(
    new
    name
    uri
    sqitch
    engine
    registry
    client
    plan_file
    plan
    top_dir
    deploy_dir
    revert_dir
    verify_dir
    extension
);

# Look at default values.
is $target->name, 'db:sqlite:', 'Name should be "db:sqlite:"';
is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite:"';
is $target->sqitch, $sqitch, 'Sqitch should be as passed';
is $target->engine_key, 'sqlite', 'Engine key should be "sqlite"';
isa_ok $target->engine, 'App::Sqitch::Engine::sqlite', 'Engine';
is $target->registry, $target->engine->default_registry,
    'Should have default registry';
is $target->client, $target->engine->default_client,
    'Should have default client';
is $target->top_dir, dir, 'Should have default top_dir';
is $target->deploy_dir, $target->top_dir->subdir('deploy'),
    'Should have default deploy_dir';
is $target->revert_dir, $target->top_dir->subdir('revert'),
    'Should have default revert_dir';
is $target->verify_dir, $target->top_dir->subdir('verify'),
    'Should have default verify_dir';
is $target->extension, 'sql', 'Should have default extension';
is $target->plan_file, $target->top_dir->file('sqitch.plan')->cleanup,
    'Should have default plan file';
isa_ok $target->plan, 'App::Sqitch::Plan', 'Should get plan';
is $target->plan->file, $target->plan_file,
    'Plan file should be copied from Target';
my $uri = $target->uri;
is $target->dsn, $uri->dbi_dsn, 'DSN should be from URI';
is $target->username, $uri->user, 'Username should be from URI';
is $target->password, $uri->password, 'Password should be from URI';

##############################################################################
# Let's look at how the object is created based on the params to new().
# First try no params.
throws_ok { $CLASS->new } qr/^Missing required arguments:/,
    'Should get error for missing params';

# Pass both name and URI.
$uri = URI::db->new('db:pg://hi:@there@localhost/blah'),
isa_ok $target = $CLASS->new(
    sqitch => $sqitch,
    name   => 'foo',
    uri    => $uri,
), $CLASS, 'Target with name and URI';

is $target->name, 'foo', 'Name should be "foo"';
is $target->uri, $uri, 'URI should be set as passed';
is $target->sqitch, $sqitch, 'Sqitch should be as passed';
is $target->engine_key, 'pg', 'Engine key should be "pg"';
isa_ok $target->engine, 'App::Sqitch::Engine::pg', 'Engine';
is $target->dsn, $uri->dbi_dsn, 'DSN should be from URI';
is $target->username, $uri->user, 'Username should be from URI';
is $target->password, $uri->password, 'Password should be from URI';

# Pass a URI but no name.
isa_ok $target = $CLASS->new(
    sqitch => $sqitch,
    uri    => $uri,
), $CLASS, 'Target with URI';
like $target->name, qr{db:pg://hi:?\@localhost/blah},
    'Name should be URI without password';
is $target->engine_key, 'pg', 'Engine key should be "pg"';
isa_ok $target->engine, 'App::Sqitch::Engine::pg', 'Engine';
is $target->dsn, $uri->dbi_dsn, 'DSN should be from URI';
is $target->username, $uri->user, 'Username should be from URI';
is $target->password, $uri->password, 'Password should be from URI';

# Set up a config.
CONFIG: {
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my @get_params;
    my @get_ret;
    $mock->mock(get => sub { shift; push @get_params => \@_; shift @get_ret; });

    # Pass neither, but rely on the engine in the Sqitch object.
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:sqlite:', 'Name should be "db:sqlite:"';
    is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite:"';
    is_deeply \@get_params, [[key => 'core.sqlite.target']],
        'Should have tried to get engine target';

    # Try with no engine option.
    @get_params = ();
    delete $sqitch->options->{engine};
    push @get_ret => 'mysql';
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:mysql:', 'Name should be "db:mysql:"';
    is $target->uri, URI::db->new('db:mysql:'), 'URI should be "db:mysql"';
    is_deeply \@get_params, [[key => 'core.engine'], [key => 'core.mysql.target']],
        'Should have tried to get core engine and its target';

    # Try it with no configured core engine or target.
    throws_ok { $CLASS->new(sqitch => $sqitch) } 'App::Sqitch::X',
        'Should have error for no engine or target';
    is $@->ident, 'target', 'Should have target ident';
    is $@->message, __(
        'No engine specified; use --engine or set core.engine'
    ), 'Should have message about no specified engine';

    # Mock get_section.
    my @sect_params;
    my @sect_ret = ({});
    $mock->mock(get_section => sub { shift; push @sect_params => \@_; shift @sect_ret; });

    # Try it with a name.
    $sqitch->options->{engine} = 'sqlite';
    @get_params = ();
    throws_ok { $CLASS->new(sqitch => $sqitch, name => 'foo') } 'App::Sqitch::X',
        'Should have exception for unknown named target';
    is $@->ident, 'target', 'Unknown target error ident should be "target"';
    is $@->message, __x(
        'Cannot find target "{target}"',
        target => 'foo',
    ), 'Unknown target error message should be correct';
    is_deeply \@get_params, [[key => 'target.foo.uri']],
        'Should have requested target URI from config';
    is_deeply \@sect_params, [[section => 'target.foo']],
        'Should have requested target.foo section';

    # Let the name section exist, but without a URI.
    @get_params = @sect_params = ();
    @sect_ret = ({ foo => 1});
    throws_ok { $CLASS->new(sqitch => $sqitch, name => 'foo') } 'App::Sqitch::X',
        'Should have exception for URL-less named target';
    is $@->ident, 'target', 'URL-less target error ident should be "target"';
    is $@->message, __x(
        'No URI associated with target "{target}"',
        target => 'foo',
    ), 'URL-less target error message should be correct';
    is_deeply \@get_params, [[key => 'target.foo.uri']],
        'Should have requested target URI from config';
    is_deeply \@sect_params, [[section => 'target.foo']],
        'Should have requested target.foo section';

    # Now give it a URI.
    @get_params = @sect_params = ();
    @get_ret = ('db:pg:foo');
    isa_ok $target = $CLASS->new(sqitch => $sqitch, name => 'foo'), $CLASS,
        'Named target';
    is $target->name, 'foo', 'Name should be "foo"';
    is $target->uri, URI::db->new('db:pg:foo'), 'URI should be "db:pg:foo"';
    is_deeply \@get_params, [[key => 'target.foo.uri']],
        'Should have requested target URI from config';
    is_deeply \@sect_params, [], 'Should have requested no section';

    # Make sure deprecated --db-* options work.
    $uri = URI::db->new('db:pg://fred@foo.com:12245/widget');
    $sqitch->options->{engine}      = 'pg';
    $sqitch->options->{db_host}     = 'foo.com';
    $sqitch->options->{db_port}     = 12245;
    $sqitch->options->{db_username} = 'fred';
    $sqitch->options->{db_name}     = 'widget';
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'SQLite target';
    is $target->name, $uri->as_string, 'Name should be stringified URI';
    is $target->uri, $uri, 'URI should be tweaked by --db-* options';
    is_deeply +MockOutput->get_warn, [[__x(
        'Options {options} deprecated and will be removed in 1.0; use URI {uri} instead',
        options => '--db-host, --db-port, --db-username, --db-name',
        uri     => $uri->as_string,
    )]], 'Should have warned on deprecated options';
}


