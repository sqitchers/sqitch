#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
use Test::Exception;
use Locale::TextDomain qw(App-Sqitch);
use List::Util qw(first);
use lib 't/lib';
use TestConfig;

my $CLASS;
BEGIN {
    $CLASS = 'App::Sqitch::Target';
    use_ok $CLASS or die;
}

##############################################################################
# Load a target and test the basics.
my $config = TestConfig->new('core.engine' => 'sqlite');
ok my $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS;
can_ok $target, qw(
    new
    name
    target
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
    reworked_dir
    reworked_deploy_dir
    reworked_revert_dir
    reworked_verify_dir
    extension
    variables
);

# Look at default values.
is $target->name, 'db:sqlite:', 'Name should be "db:sqlite:"';
is $target->target, $target->name, 'Target should be alias for name';
is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite:"';
is $target->sqitch, $sqitch, 'Sqitch should be as passed';
is $target->engine_key, 'sqlite', 'Engine key should be "sqlite"';
isa_ok $target->engine, 'App::Sqitch::Engine::sqlite', 'Engine';
is $target->registry, $target->engine->default_registry,
    'Should have default registry';
my $client = $target->engine->default_client;
$client .= '.exe' if App::Sqitch::ISWIN && $client !~ /[.](?:exe|bat)$/;
is $target->client, $client, 'Should have default client';
is $target->top_dir, dir, 'Should have default top_dir';
is $target->deploy_dir, $target->top_dir->subdir('deploy'),
    'Should have default deploy_dir';
is $target->revert_dir, $target->top_dir->subdir('revert'),
    'Should have default revert_dir';
is $target->verify_dir, $target->top_dir->subdir('verify'),
    'Should have default verify_dir';
is $target->reworked_dir, $target->top_dir, 'Should have default reworked_dir';
is $target->reworked_deploy_dir, $target->reworked_dir->subdir('deploy'),
    'Should have default reworked_deploy_dir';
is $target->reworked_revert_dir, $target->reworked_dir->subdir('revert'),
    'Should have default reworked_revert_dir';
is $target->reworked_verify_dir, $target->reworked_dir->subdir('verify'),
    'Should have default reworked_verify_dir';
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
is_deeply $target->variables, {}, 'Variables should be empty';

do {
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS;
    local $ENV{SQITCH_USERNAME} = 'kamala';
    local $ENV{SQITCH_PASSWORD} = 'S3cre7s';
    is $target->username, $ENV{SQITCH_USERNAME},
        'Username should be from environment variable';
    is $target->password, $ENV{SQITCH_PASSWORD},
        'Password should be from environment variable';
};

##############################################################################
# Let's look at how the object is created based on the params to new().
# First try no params.
throws_ok { $CLASS->new } qr/^Missing required arguments:/,
    'Should get error for missing params';

# Pass both name and URI.
$uri = URI::db->new('db:pg://hi:there@localhost/blah'),
isa_ok $target = $CLASS->new(
    sqitch => $sqitch,
    name   => 'foo',
    uri    => $uri,
    variables => {a => 1},
), $CLASS, 'Target with name and URI';

is $target->name, 'foo', 'Name should be "foo"';
is $target->target, $target->name, 'Target should be alias for name';
is $target->uri, $uri, 'URI should be set as passed';
is $target->sqitch, $sqitch, 'Sqitch should be as passed';
is $target->engine_key, 'pg', 'Engine key should be "pg"';
isa_ok $target->engine, 'App::Sqitch::Engine::pg', 'Engine';
is $target->dsn, $uri->dbi_dsn, 'DSN should be from URI';
is $target->username, 'hi', 'Username should be from URI';
do {
    local $ENV{SQITCH_PASSWORD} = 'lolz';
    is $target->password, 'lolz', 'Password should be from environment';
};
is_deeply $target->variables, {a => 1}, 'Variables should be set';

# Pass a URI but no name.
isa_ok $target = $CLASS->new(
    sqitch => $sqitch,
    uri    => $uri,
), $CLASS, 'Target with URI';
like $target->name, qr{db:pg://hi:?\@localhost/blah},
    'Name should be URI without password';
is $target->target, $target->name, 'Target should be alias for name';
is $target->engine_key, 'pg', 'Engine key should be "pg"';
isa_ok $target->engine, 'App::Sqitch::Engine::pg', 'Engine';
is $target->dsn, $uri->dbi_dsn, 'DSN should be from URI';
is $target->username, $uri->user, 'Username should be from URI';
is $target->password, $uri->password, 'Password should be from URI';

# Set the URI via SQITCH_TARGET.
ENV: {
    local $ENV{SQITCH_TARGET} = 'db:pg:';
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS,
        'Target from environment';
    is $target->name, 'db:pg:', 'Name should be set';
    is $target->uri, 'db:pg:', 'URI should be set';
    is $target->engine_key, 'pg', 'Engine key should be "pg"';
    isa_ok $target->engine, 'App::Sqitch::Engine::pg', 'Engine';
}

# Set up a config.
CONSTRUCTOR: {
    my (@get_params, $orig_get);
    my $mock = TestConfig->mock(
        get => sub { my $c = shift; push @get_params => \@_; $orig_get->($c, @_); }
    );
    $orig_get = $mock->original('get');
    $config->replace('core.engine' => 'sqlite');

    # Pass neither, but rely on the engine in the Sqitch object.
    my $sqitch = App::Sqitch->new(config => $config);
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:sqlite:', 'Name should be "db:sqlite:"';
    is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite:"';
    is_deeply \@get_params, [
        [key => 'core.target'],
        [key => 'core.engine'],
        [key => 'engine.sqlite.target'],
    ], 'Should have tried to get engine target';

    # Try with just core.engine.
    delete $sqitch->options->{engine};
    $config->update('core.engine' => 'mysql');
    @get_params = ();
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:mysql:', 'Name should be "db:mysql:"';
    is $target->uri, URI::db->new('db:mysql:'), 'URI should be "db:mysql"';
    is_deeply \@get_params, [
        [key => 'core.target'],
        [key => 'core.engine'],
        [key => 'engine.mysql.target'],
    ], 'Should have tried to get core.target, core.engine and then the target';

    # Try with no engine option but a name that looks like a URI.
    @get_params = ();
    delete $sqitch->options->{engine};
    isa_ok $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'db:pg:',
    ), $CLASS, 'Target with URI in name';
    is $target->name, 'db:pg:', 'Name should be "db:pg:"';
    is $target->uri, URI::db->new('db:pg:'), 'URI should be "db:pg"';
    is_deeply \@get_params, [], 'Should have fetched no config';

    # Try it with a name with no engine.
    throws_ok { $CLASS->new(sqitch => $sqitch, name => 'db:') } 'App::Sqitch::X',
        'Should have error for no engine in URI';
    is $@->ident, 'target', 'Should have target ident';
    is $@->message, __x(
        'No engine specified by URI {uri}; URI must start with "db:$engine:"',
        uri => 'db:',
    ), 'Should have message about no engine-less URI';

    # Try it with no configured core engine or target.
    $config->replace;
    throws_ok { $CLASS->new(sqitch => $sqitch) } 'App::Sqitch::X',
        'Should have error for no engine or target';
    is $@->ident, 'target', 'Should have target ident';
    is $@->message, __(
        'No project configuration found. Run the "init" command to initialize a project',
    ), 'Should have message about no configuration';

    # Try it with a config file but no engine config.
    MOCK: {
        my $mock_init = TestConfig->mock(initialized => 1);
        throws_ok { $CLASS->new(sqitch => $sqitch) } 'App::Sqitch::X',
            'Should again have error for no engine or target';
        is $@->ident, 'target', 'Should have target ident again';
        is $@->message, __(
            'No engine specified; specify via target or core.engine',
        ), 'Should have message about no specified engine';
    }

    # Try with engine-less URI.
    @get_params = ();
    isa_ok $target = $CLASS->new(
        sqitch => $sqitch,
        uri    => URI::db->new('db:'),
    ), $CLASS, 'Engineless target';
    is $target->name, 'db:', 'Name should be "db:"';
    is $target->uri, URI::db->new('db:'), 'URI should be "db:"';
    is_deeply \@get_params, [], 'Should not have tried to get engine target';

    is $target->sqitch, $sqitch, 'Sqitch should be as passed';
    is $target->engine_key, undef, 'Engine key should be undef';
    throws_ok { $target->engine } 'App::Sqitch::X',
        'Should get exception for no engine';
    is $@->ident, 'engine', 'Should have engine ident';
    is $@->message, __(
        'No engine specified; specify via target or core.engine',
    ), 'Should have message about no engine';

    is $target->top_dir, dir, 'Should have default top_dir';
    is $target->deploy_dir, $target->top_dir->subdir('deploy'),
        'Should have default deploy_dir';
    is $target->revert_dir, $target->top_dir->subdir('revert'),
        'Should have default revert_dir';
    is $target->verify_dir, $target->top_dir->subdir('verify'),
        'Should have default verify_dir';
    is $target->reworked_dir, $target->top_dir, 'Should have default reworked_dir';
    is $target->reworked_deploy_dir, $target->reworked_dir->subdir('deploy'),
        'Should have default reworked_deploy_dir';
    is $target->reworked_revert_dir, $target->reworked_dir->subdir('revert'),
        'Should have default reworked_revert_dir';
    is $target->reworked_verify_dir, $target->reworked_dir->subdir('verify'),
        'Should have default reworked_verify_dir';
    is $target->extension, 'sql', 'Should have default extension';
    is $target->plan_file, $target->top_dir->file('sqitch.plan')->cleanup,
        'Should have default plan file';
    isa_ok $target->plan, 'App::Sqitch::Plan', 'Should get plan';
    is $target->plan->file, $target->plan_file,
        'Plan file should be copied from Target';
    is $target->dsn, '', 'DSN should be empty';
    is $target->username, undef, 'Username should be undef';
    is $target->password, undef, 'Password should be undef';

    # Try passing a proper URI via the name.
    @get_params = ();
    isa_ok $target = $CLASS->new(sqitch => $sqitch, name => 'db:pg://a:b@foo/scat'), $CLASS,
        'Engine URI target';
    like $target->name, qr{db:pg://a:?\@foo/scat}, 'Name should be "db:pg://a@foo/scat"';
    is $target->uri, URI::db->new('db:pg://a:b@foo/scat'),
        'URI should be "db:pg://a:b@foo/scat"';
    is_deeply \@get_params, [], 'Nothing should have been fetched from config';

    # Pass nothing, but let a URI be in core.target.
    @get_params = ();
    $config->update('core.target' => 'db:pg://s:b@ack/shi');
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS,
        'Engine URI core.target';
    like $target->name, qr{db:pg://s:?\@ack/shi}, 'Name should be "db:pg://s@ack/shi"';
    is $target->uri, URI::db->new('db:pg://s:b@ack/shi'),
        'URI should be "db:pg://s:b@ack/shi"';
    is_deeply \@get_params, [[key => 'core.target']],
        'Should have fetched core.target from config';

    # Pass nothing, but let a target name be in core.target.
    @get_params = ();
    $config->update(
        'core.target'      => 'shout',
        'target.shout.uri' => 'db:pg:w:e@we/bar',
    );
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS,
        'Engine name core.target';
    is $target->name, 'shout', 'Name should be "shout"';
    is $target->uri, URI::db->new('db:pg:w:e@we/bar'),
        'URI should be "db:pg:w:e@we/bar"';
    is_deeply \@get_params, [
        [key => 'core.target'],
        [key => 'target.shout.uri']
    ], 'Should have fetched target.shout.uri from config';

    # Mock get_section.
    my (@sect_params, $orig_sect);
    $mock->mock(get_section => sub {
        my $c = shift; push @sect_params => \@_; $orig_sect->($c, @_);
    });
    $orig_sect = $mock->original('get_section');

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
    $config->replace('target.foo.bar' => 1);
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
    $config->replace( 'target.foo.uri' => 'db:pg:foo');
    $sqitch = App::Sqitch->new(config => $config);
    isa_ok $target = $CLASS->new(sqitch => $sqitch, name => 'foo'), $CLASS,
        'Named target';
    is $target->name, 'foo', 'Name should be "foo"';
    is $target->uri, URI::db->new('db:pg:foo'), 'URI should be "db:pg:foo"';
    is_deeply \@get_params, [[key => 'target.foo.uri']],
        'Should have requested target URI from config';
    is_deeply \@sect_params, [],
        'Should not have requested deprecated pg section';

    # Let the name be looked up by the engine.
    @get_params = @sect_params = ();
    $config->update(
        'core.target'    => 'foo',
        'target.foo.uri' => 'db:sqlite:foo',
    );
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Engine named target';
    is $target->name, 'foo', 'Name should be "foo"';
    is $target->uri, URI::db->new('db:sqlite:foo'), 'URI should be "db:sqlite:foo"';
    is_deeply \@get_params, [
        [key => 'core.target'],
        [key => 'target.foo.uri']
    ], 'Should have requested engine target and target URI from config';
    is_deeply \@sect_params, [], 'Should have requested no section';

    # Let the name come from the environment.
    ENV: {
        @get_params = @sect_params = ();
        $config->replace('target.bar.uri' => 'db:sqlite:bar');
        local $ENV{SQITCH_TARGET} = 'bar';
        isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Environment-named target';
        is $target->name, 'bar', 'Name should be "bar"';
        is $target->uri, URI::db->new('db:sqlite:bar'), 'URI should be "db:sqlite:bar"';
        is_deeply \@get_params, [[key => 'target.bar.uri']],
            'Should have requested target URI from config';
        is_deeply \@sect_params, [], 'Should have requested no sections';
    }

    # Make sure uri params work.
    @get_params = @sect_params = ();
    $config->replace('core.engine' => 'pg');
    $uri = URI::db->new('db:pg://fred@foo.com:12245/widget');
    isa_ok $target = $CLASS->new(
        sqitch => $sqitch,
        host   => 'foo.com',
        port   => 12245,
        user   => 'fred',
        dbname => 'widget',
    ), $CLASS, 'URI-munged target';
    is_deeply \@sect_params, [], 'Should have requested no section';
    like $target->name, qr{db:pg://fred:?\@foo.com:12245/widget},
        'Name should be passwordless stringified URI';
    is $target->uri, $uri, 'URI should be tweaked by URI params';

    # URI params should work when URI read from target config.
    $uri = URI::db->new('db:pg://foo.com/widget');
    @get_params = @sect_params = ();
    $sqitch->options->{db_host} = 'foo.com';
    $sqitch->options->{db_name} = 'widget';
    $config->update('target.foo.uri' => 'db:pg:');
    isa_ok $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'foo',
        host   => 'foo.com',
        dbname => 'widget',
    ), $CLASS, 'Foo target';
    is_deeply \@get_params, [ [key => 'target.foo.uri' ]],
        'Should have requested target URI';
    is_deeply \@sect_params, [], 'Should have fetched no section';
    is $target->name, 'foo', 'Name should be as passed';
    is $target->uri, $uri, 'URI should be tweaked by URI params';

    # URI params should work when URI passsed.
    $uri = URI::db->new('db:pg://:1919/');
    @get_params = @sect_params = ();
    $sqitch->options->{db_host} = 'foo.com';
    $sqitch->options->{db_name} = 'widget';
    isa_ok $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'db:pg:widget',
        host   => '',
        dbname => '',
        port   => 1919,
    ), $CLASS, 'URI target';
    is_deeply \@get_params, [], 'Should have requested no config';
    is_deeply \@sect_params, [], 'Should have fetched no section';
    is $target->name, $uri, 'Name should tweaked by URI params';
    is $target->uri, $uri, 'URI should be tweaked by URI params';
}

CONFIG: {
    # Look at how attributes are populated from options, config.
    my $opts = {};
    $config->replace(
        'core.engine'              => 'pg',
        'core.registry'            => 'myreg',
        'core.client'              => 'pgsql',
        'core.plan_file'           => 'my.plan',
        'core.top_dir'             => 'top',
        'core.deploy_dir'          => 'dep',
        'core.revert_dir'          => 'rev',
        'core.verify_dir'          => 'ver',
        'core.reworked_dir'        => 'wrk',
        'core.reworked_deploy_dir' => 'rdep',
        'core.reworked_revert_dir' => 'rrev',
        'core.reworked_verify_dir' => 'rver',
        'core.extension'           => 'ddl',
    );
    my $sqitch = App::Sqitch->new(options => $opts, config => $config);
    my $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'foo',
        uri    => URI::db->new('db:pg:foo'),
    );

    is $target->registry, 'myreg', 'Registry should be "myreg"';
    is $target->client, 'pgsql', 'Client should be "pgsql"';
    is $target->plan_file, 'my.plan', 'Plan file should be "my.plan"';
    isa_ok $target->plan_file, 'Path::Class::File', 'Plan file';
    isa_ok my $plan = $target->plan, 'App::Sqitch::Plan', 'Plan';
    is $plan->file, $target->plan_file, 'Plan should use target plan file';
    is $target->top_dir, 'top', 'Top dir should be "top"';
    isa_ok $target->top_dir, 'Path::Class::Dir', 'Top dir';
    is $target->deploy_dir, 'dep', 'Deploy dir should be "dep"';
    isa_ok $target->deploy_dir, 'Path::Class::Dir', 'Deploy dir';
    is $target->revert_dir, 'rev', 'Revert dir should be "rev"';
    isa_ok $target->revert_dir, 'Path::Class::Dir', 'Revert dir';
    is $target->verify_dir, 'ver', 'Verify dir should be "ver"';
    isa_ok $target->verify_dir, 'Path::Class::Dir', 'Verify dir';
    is $target->reworked_dir, 'wrk', 'Reworked dir should be "wrk"';
    isa_ok $target->reworked_dir, 'Path::Class::Dir', 'Reworked dir';
    is $target->reworked_deploy_dir, 'rdep', 'Reworked deploy dir should be "rdep"';
    isa_ok $target->reworked_deploy_dir, 'Path::Class::Dir', 'Reworked deploy dir';
    is $target->reworked_revert_dir, 'rrev', 'Reworked revert dir should be "rrev"';
    isa_ok $target->reworked_revert_dir, 'Path::Class::Dir', 'Reworked revert dir';
    is $target->reworked_verify_dir, 'rver', 'Reworked verify dir should be "rver"';
    isa_ok $target->reworked_verify_dir, 'Path::Class::Dir', 'Reworked verify dir';
    is $target->extension, 'ddl', 'Extension should be "ddl"';
    is_deeply $target->variables, {}, 'Should have no variables';

    # Add engine config.
    $config->update(
        'engine.pg.registry'            => 'yoreg',
        'engine.pg.client'              => 'mycli',
        'engine.pg.plan_file'           => 'pg.plan',
        'engine.pg.top_dir'             => 'pg',
        'engine.pg.deploy_dir'          => 'pgdep',
        'engine.pg.revert_dir'          => 'pgrev',
        'engine.pg.verify_dir'          => 'pgver',
        'engine.pg.reworked_dir'        => 'pg/r',
        'engine.pg.reworked_deploy_dir' => 'pgrdep',
        'engine.pg.reworked_revert_dir' => 'pgrrev',
        'engine.pg.reworked_verify_dir' => 'pgrver',
        'engine.pg.extension'           => 'pgddl',
        'engine.pg.variables'           => { x => 'ex', y => 'why', z => 'zee' },
    );
    $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'foo',
        uri    => URI::db->new('db:pg:foo'),
    );

    is $target->registry, 'yoreg', 'Registry should be "yoreg"';
    is $target->client, 'mycli', 'Client should be "mycli"';
    is $target->plan_file, 'pg.plan', 'Plan file should be "pg.plan"';
    isa_ok $target->plan_file, 'Path::Class::File', 'Plan file';
    isa_ok $plan = $target->plan, 'App::Sqitch::Plan', 'Plan';
    is $plan->file, $target->plan_file, 'Plan should use target plan file';
    is $target->top_dir, 'pg', 'Top dir should be "pg"';
    isa_ok $target->top_dir, 'Path::Class::Dir', 'Top dir';
    is $target->deploy_dir, 'pgdep', 'Deploy dir should be "pgdep"';
    isa_ok $target->deploy_dir, 'Path::Class::Dir', 'Deploy dir';
    is $target->revert_dir, 'pgrev', 'Revert dir should be "pgrev"';
    isa_ok $target->revert_dir, 'Path::Class::Dir', 'Revert dir';
    is $target->verify_dir, 'pgver', 'Verify dir should be "pgver"';
    isa_ok $target->verify_dir, 'Path::Class::Dir', 'Verify dir';
    is $target->reworked_dir, dir('pg/r'), 'Reworked dir should be "pg/r"';
    isa_ok $target->reworked_dir, 'Path::Class::Dir', 'Reworked dir';
    is $target->reworked_deploy_dir, 'pgrdep', 'Reworked deploy dir should be "pgrdep"';
    isa_ok $target->reworked_deploy_dir, 'Path::Class::Dir', 'Reworked deploy dir';
    is $target->reworked_revert_dir, 'pgrrev', 'Reworked revert dir should be "pgrrev"';
    isa_ok $target->reworked_revert_dir, 'Path::Class::Dir', 'Reworked revert dir';
    is $target->reworked_verify_dir, 'pgrver', 'Reworked verify dir should be "pgrver"';
    isa_ok $target->reworked_verify_dir, 'Path::Class::Dir', 'Reworked verify dir';
    is $target->extension, 'pgddl', 'Extension should be "pgddl"';
    is_deeply $target->variables, {x => 'ex', y => 'why', z => 'zee'},
        'Variables should be read from engine.variables';

    # Add target config.
    $config->update(
        'target.foo.registry'            => 'fooreg',
        'target.foo.client'              => 'foocli',
        'target.foo.plan_file'           => 'foo.plan',
        'target.foo.top_dir'             => 'foo',
        'target.foo.deploy_dir'          => 'foodep',
        'target.foo.revert_dir'          => 'foorev',
        'target.foo.verify_dir'          => 'foover',
        'target.foo.reworked_dir'        => 'foo/r',
        'target.foo.reworked_deploy_dir' => 'foodepr',
        'target.foo.reworked_revert_dir' => 'foorevr',
        'target.foo.reworked_verify_dir' => 'fooverr',
        'target.foo.extension'           => 'fooddl',
        'engine.pg.variables'            => { z => 'zie',  a => 'ay' },
    );
    $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'foo',
        uri    => URI::db->new('db:pg:foo'),
    );

    is $target->registry, 'fooreg', 'Registry should be "fooreg"';
    is $target->client, 'foocli', 'Client should be "foocli"';
    is $target->plan_file, 'foo.plan', 'Plan file should be "foo.plan"';
    isa_ok $target->plan_file, 'Path::Class::File', 'Plan file';
    isa_ok $plan = $target->plan, 'App::Sqitch::Plan', 'Plan';
    is $plan->file, $target->plan_file, 'Plan should use target plan file';
    is $target->top_dir, 'foo', 'Top dir should be "foo"';
    isa_ok $target->top_dir, 'Path::Class::Dir', 'Top dir';
    is $target->deploy_dir, 'foodep', 'Deploy dir should be "foodep"';
    isa_ok $target->deploy_dir, 'Path::Class::Dir', 'Deploy dir';
    is $target->revert_dir, 'foorev', 'Revert dir should be "foorev"';
    isa_ok $target->revert_dir, 'Path::Class::Dir', 'Revert dir';
    is $target->verify_dir, 'foover', 'Verify dir should be "foover"';
    isa_ok $target->verify_dir, 'Path::Class::Dir', 'Verify dir';
    is $target->reworked_dir, dir('foo/r'), 'Reworked dir should be "foo/r"';
    isa_ok $target->reworked_dir, 'Path::Class::Dir', 'Reworked dir';
    is $target->reworked_deploy_dir, 'foodepr', 'Reworked deploy dir should be "foodepr"';
    isa_ok $target->reworked_deploy_dir, 'Path::Class::Dir', 'Reworked deploy dir';
    is $target->reworked_revert_dir, 'foorevr', 'Reworked revert dir should be "foorevr"';
    isa_ok $target->reworked_revert_dir, 'Path::Class::Dir', 'Reworked revert dir';
    is $target->reworked_verify_dir, 'fooverr', 'Reworked verify dir should be "fooverr"';
    isa_ok $target->reworked_verify_dir, 'Path::Class::Dir', 'Reworked verify dir';
    is $target->extension, 'fooddl', 'Extension should be "fooddl"';
    is_deeply $target->variables, {x => 'ex', y => 'why', z => 'zie', a => 'ay'},
        'Variables should be read from engine., and target.variables';
}

sub _load($) {
    my $config = App::Sqitch::Config->new;
    $config->load_file(file 't', "$_[0].conf");
    return $config;
}

ALL: {
    # Let's test loading all targets. Start with only core.
    my $config = TestConfig->from(local => file qw(t core.conf) );
    my $sqitch = App::Sqitch->new(config => $config);
    ok my @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all targets';
    is @targets, 1, 'Should have one target';
    is $targets[0]->name, 'db:pg:',
        'It should be the generic core engine target';

    # Now load one with a core target defined.
    $config = TestConfig->from(local => file qw(t core_target.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok @targets = $CLASS->all_targets(sqitch => $sqitch),
        'Load all targets with core target config';
    is @targets, 1, 'Should again have one target';
    is $targets[0]->name, 'db:pg:whatever', 'It should be the named target';
    is_deeply $targets[0]->variables, {}, 'It should have no variables';

    # Try it with both engine and target defined.
    $sqitch->config->load_file(file 't', 'core.conf');
    ok @targets = $CLASS->all_targets(sqitch => $sqitch),
        'Load all targets with core engine and target config';
    is @targets, 1, 'Should still have one target';
    is $targets[0]->name, 'db:pg:whatever', 'It should again be the named target';
    is_deeply $targets[0]->variables, {}, 'It should have no variables';

    # Great, now let's load one with some engines in it.
    $config = TestConfig->from(local => file qw(t user.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all user conf targets';
    is @targets, 4, 'Should have four user targets';
    is_deeply [ sort map { $_->name } @targets ], [
        'db:firebird:',
        'db:mysql:',
        'db:pg://postgres@localhost/thingies',
        'db:sqlite:my.db',
    ], 'Should have all the engine targets';
    my $mysql = first { $_->name eq 'db:mysql:' } @targets;
    is_deeply $mysql->variables, {prefix => 'foo_'},
        'MySQL target should have engine variables';

    # Load one with targets.
    $config = TestConfig->from(local => file qw(t target.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all target conf targets';
    is @targets, 4, 'Should have three targets';
    is $targets[0]->name, 'db:pg:', 'Core engine should be default target';
    is_deeply [ sort map { $_->name } @targets ], [qw(db:pg: dev prod qa)],
        'Should have the core target plus the named targets';

    # Load one with engines and targets.
    $config = TestConfig->from(local => file qw(t local.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all local conf targets';
    is @targets, 2, 'Should have two local targets';
    is $targets[0]->name, 'mydb', 'Core engine should be lead to default target';
    is_deeply [ sort map { $_->name } @targets ], [qw(devdb mydb)],
        'Should have the core target plus the named targets';

    # Mix up a core engine, engines, and targets.
    $config = TestConfig->from(local => file qw(t engine.conf) );
    $sqitch = App::Sqitch->new(config => $config);
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all engine conf targets';
    is @targets, 3, 'Should have three engine conf targets';
    is_deeply [ sort map { $_->name } @targets ],
        [qw(db:mysql://root@/foo db:pg:try widgets)],
        'Should have the engine and target targets';

    # Make sure parameters are set on all targets.
    ok @targets = $CLASS->all_targets(
        sqitch => $sqitch,
        registry => 'quack',
        dbname   => 'w00t',
    ), 'Overload all engine conf targets';
    is @targets, 3, 'Should again have three engine conf targets';
    is_deeply [ sort map { $_->uri->as_string } @targets ],
        [qw(db:mysql://root@/w00t db:pg:w00t db:sqlite:w00t)],
        'Should have set dbname on all target URIs';
    is_deeply [ map { $_->registry } @targets ], [('quack') x 3],
        'Should have set the registry on all targets.';
}

done_testing;
