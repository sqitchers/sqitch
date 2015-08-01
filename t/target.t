#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More;
use App::Sqitch;
use Path::Class qw(dir file);
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
    extension
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
$client .= '.exe' if $^O eq 'MSWin32' && $client !~ /[.](?:exe|bat)$/;
is $target->client, $client, 'Should have default client';
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

do {
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS;
    local $ENV{SQITCH_PASSWORD} = 'S3cre7s';
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

# Set up a config.
CONSTRUCTOR: {
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my @get_params;
    my @get_ret;
    $mock->mock(get => sub { shift; push @get_params => \@_; shift @get_ret; });

    # Pass neither, but rely on the engine in the Sqitch object.
    isa_ok my $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:sqlite:', 'Name should be "db:sqlite:"';
    is $target->uri, URI::db->new('db:sqlite:'), 'URI should be "db:sqlite:"';
    is_deeply \@get_params, [[key => 'engine.sqlite.target'],[key => 'core.sqlite.target']],
        'Should have tried to get engine target';

    # Try with no engine option.
    @get_params = ();
    delete $sqitch->options->{engine};
    push @get_ret => undef, 'mysql';
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Default target';
    is $target->name, 'db:mysql:', 'Name should be "db:mysql:"';
    is $target->uri, URI::db->new('db:mysql:'), 'URI should be "db:mysql"';
    is_deeply \@get_params, [
        [key => 'core.target'],
        [key => 'core.engine'],
        [key => 'engine.mysql.target'],
        [key => 'core.mysql.target'],
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
    throws_ok { $CLASS->new(sqitch => $sqitch) } 'App::Sqitch::X',
        'Should have error for no engine or target';
    is $@->ident, 'target', 'Should have target ident';
    is $@->message, __(
        'No engine specified; use --engine or set core.engine'
    ), 'Should have message about no specified engine';

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
        'No engine specified; use --engine or set core.engine'
    ), 'Should have message about no engine';

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
    push @get_ret => 'db:pg://s:b@ack/shi';
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS,
        'Engine URI core.target';
    like $target->name, qr{db:pg://s:?\@ack/shi}, 'Name should be "db:pg://s@ack/shi"';
    is $target->uri, URI::db->new('db:pg://s:b@ack/shi'),
        'URI should be "db:pg://s:b@ack/shi"';
    is_deeply \@get_params, [[key => 'core.target']],
        'Should have fetched core.target from config';

    # Pass nothing, but let a target name be in core.target.
    @get_params = ();
    push @get_ret => 'shout', 'db:pg:w:e@we/bar';
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
    is_deeply \@sect_params, [],
        'Should not have requested deprecated pg section';

    # Let the name be looked up by the engine.
    @get_params = @sect_params = ();
    @get_ret = ('foo', 'db:sqlite:foo');
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS,
        'Engine named target';
    is $target->name, 'foo', 'Name should be "foo"';
    is $target->uri, URI::db->new('db:sqlite:foo'), 'URI should be "db:sqlite:foo"';
    is_deeply \@get_params, [[key => 'engine.sqlite.target'], [key => 'target.foo.uri']],
        'Should have requested engine target and target URI from config';
    is_deeply \@sect_params, [], 'Should not have requested pg section';

    # Make sure db options and deprecated config variables work.
    local $App::Sqitch::Target::WARNED = 0;
    @sect_ret = ({
        host     => 'hi.com',
        port     => 5432,
        username => 'bob',
        password => 'ouch',
        db_name  => 'sharks',
    });
    $sqitch->options->{engine} = 'pg';
    @get_params = @sect_params = ();
    $uri = URI::db->new('db:pg://bob:ouch@hi.com:5432/sharks');
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Pg target';
    is_deeply \@sect_params, [ [section => 'core.pg' ], [section => 'engine.pg' ]],
        'Should have requested core and engine pg sections';
    like $target->name, qr{db:pg://bob:?\@hi.com:5432/sharks},
        'Name should be passwordless stringified URI';
    is $target->uri, $uri, 'URI should be tweaked by config* options';
    is_deeply +MockOutput->get_warn, [[__x(
        "The core.{engine} config has been deprecated in favor of engine.{engine}.\nRun '{sqitch} engine update-config' to update your configurations.",
        engine => 'pg',
        sqitch => $0,
    )]], 'Should have warned on deprecated config options';

    # Make sure --db-* options work.
    $App::Sqitch::Target::WARNED = 0;
    @sect_ret = ({
        host     => 'hi.com',
        port     => 5432,
        username => 'bob',
        password => 'ouch',
        db_name  => 'sharks',
    });
    @get_params = @sect_params = ();
    $uri = URI::db->new('db:pg://fred:ouch@foo.com:12245/widget');
    $sqitch->options->{db_host}     = 'foo.com';
    $sqitch->options->{db_port}     = 12245;
    $sqitch->options->{db_username} = 'fred';
    $sqitch->options->{db_name}     = 'widget';
    isa_ok $target = $CLASS->new(sqitch => $sqitch), $CLASS, 'Postgres target';
    is_deeply \@sect_params, [ [section => 'core.pg' ], [section => 'engine.pg' ] ],
        'Should have requested sqlite core and engine sections';
    like $target->name, qr{db:pg://fred:?\@foo.com:12245/widget},
        'Name should be passwordless stringified URI';
    is $target->uri, $uri, 'URI should be tweaked by --db-* options';
    is_deeply +MockOutput->get_warn, [
        [__x(
            "The core.{engine} config has been deprecated in favor of engine.{engine}.\nRun '{sqitch} engine update-config' to update your configurations.",
            engine => 'pg',
            sqitch => $0,
        )],
    ], 'Should have warned on deprecated config';

    # Options should work, but not config, when URI read from target config.
    $App::Sqitch::Target::WARNED = 0;
    @sect_ret = ({
        host     => 'hi.com',
    });
    $uri = URI::db->new('db:pg://foo.com/widget');
    @get_ret = ('db:pg:');
    @get_params = @sect_params = ();
    delete $sqitch->{options}->{$_} for qw(engine db_port db_username);
    $sqitch->options->{db_host} = 'foo.com';
    $sqitch->options->{db_name} = 'widget';
    isa_ok $target = $CLASS->new(sqitch => $sqitch, name => 'foo'), $CLASS,
        'Foo target';
    is_deeply \@get_params, [ [key => 'target.foo.uri' ]],
        'Should have requested target URI';
    is_deeply \@sect_params, [], 'Should have fetched no section';
    is $target->name, 'foo', 'Name should be as passed';
    is $target->uri, $uri, 'URI should be tweaked by --db-* options';
    is_deeply +MockOutput->get_warn, [],
        'Should have emitted no warnigns';
}

CONFIG: {
    # Look at how attributes are populated from options, config.
    my $opts = { engine => 'pg' };
    my $sqitch = App::Sqitch->new(options => $opts);

    # Mock config.
    my $mock = Test::MockModule->new('App::Sqitch::Config');
    my %config;
    $mock->mock(get => sub { $config{$_[2]} });

    # Start with core config.
    %config = (
        'core.registry'   => 'myreg',
        'core.client'     => 'pgsql',
        'core.plan_file'  => 'my.plan',
        'core.top_dir'    => 'top',
        'core.deploy_dir' => 'dep',
        'core.revert_dir' => 'rev',
        'core.verify_dir' => 'ver',
        'core.extension'  => 'ddl',
    );
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
    is $target->extension, 'ddl', 'Extension should be "ddl"';

    # Add engine config.
    $config{'engine.pg.registry'}   = 'yoreg';
    $config{'engine.pg.client'}     = 'mycli';
    $config{'engine.pg.plan_file'}  = 'pg.plan';
    $config{'engine.pg.top_dir'}    = 'pg';
    $config{'engine.pg.deploy_dir'} = 'pgdep';
    $config{'engine.pg.revert_dir'} = 'pgrev';
    $config{'engine.pg.verify_dir'} = 'pgver';
    $config{'engine.pg.extension'}  = 'pgddl';
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
    is $target->extension, 'pgddl', 'Extension should be "pgddl"';

    # Add target config.
    $config{'target.foo.registry'}   = 'fooreg';
    $config{'target.foo.client'}     = 'foocli';
    $config{'target.foo.plan_file'}  = 'foo.plan';
    $config{'target.foo.top_dir'}    = 'foo';
    $config{'target.foo.deploy_dir'} = 'foodep';
    $config{'target.foo.revert_dir'} = 'foorev';
    $config{'target.foo.verify_dir'} = 'foover';
    $config{'target.foo.extension'}  = 'fooddl';
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
    is $target->extension, 'fooddl', 'Extension should be "fooddl"';

    # Add command-line options.
    $opts->{registry}   = 'optreg';
    $opts->{client}     = 'optcli';
    $opts->{plan_file}  = 'opt.plan';
    $opts->{top_dir}    = 'top.dir';
    $opts->{deploy_dir} = 'dep.dir';
    $opts->{revert_dir} = 'rev.dir';
    $opts->{verify_dir} = 'ver.dir';
    $opts->{extension}  = 'opt';
    $target = $CLASS->new(
        sqitch => $sqitch,
        name   => 'foo',
        uri    => URI::db->new('db:pg:foo'),
    );

    is $target->registry, 'optreg', 'Registry should be "optreg"';
    is $target->client, 'optcli', 'Client should be "optcli"';
    is $target->plan_file, 'opt.plan', 'Plan file should be "opt.plan"';
    isa_ok $target->plan_file, 'Path::Class::File', 'Plan file';
    isa_ok $plan = $target->plan, 'App::Sqitch::Plan', 'Plan';
    is $plan->file, $target->plan_file, 'Plan should use target plan file';
    is $target->top_dir, 'top.dir', 'Top dir should be "top.dir"';
    isa_ok $target->top_dir, 'Path::Class::Dir', 'Top dir';
    is $target->deploy_dir, 'dep.dir', 'Deploy dir should be "dep.dir"';
    isa_ok $target->deploy_dir, 'Path::Class::Dir', 'Deploy dir';
    is $target->revert_dir, 'rev.dir', 'Revert dir should be "rev.dir"';
    isa_ok $target->revert_dir, 'Path::Class::Dir', 'Revert dir';
    is $target->verify_dir, 'ver.dir', 'Verify dir should be "ver.dir"';
    isa_ok $target->verify_dir, 'Path::Class::Dir', 'Verify dir';
    is $target->extension, 'opt', 'Extension should be "opt"';
}

sub _load($) {
    my $config = App::Sqitch::Config->new;
    $config->load_file(file 't', "$_[0].conf");
    return $config;
}

ALL: {
    # Let's test loading all targets. Start with only core.
    local $ENV{SQITCH_CONFIG} = file qw(t core.conf);
    my $sqitch = App::Sqitch->new;
    ok my @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all targets';
    is @targets, 1, 'Should have one target';
    is $targets[0]->name, 'db:pg:',
        'It should be the generic core enginetarget';

    # Now load one with a core target defined.
    $ENV{SQITCH_CONFIG} = file qw(t core_target.conf);
    $sqitch = App::Sqitch->new;
    ok @targets = $CLASS->all_targets(sqitch => $sqitch),
        'Load all targets with core target config';
    is @targets, 1, 'Should again have one target';
    is $targets[0]->name, 'db:pg:whatever', 'It should be the named target';

    # Try it with both engine and target defined.
    $sqitch->config->load_file(file 't', 'core.conf');
    ok @targets = $CLASS->all_targets(sqitch => $sqitch),
        'Load all targets with core engine and target config';
    is @targets, 1, 'Should still have one target';
    is $targets[0]->name, 'db:pg:whatever', 'It should again be the named target';

    # Great, now let's load one with some engines in it.
    $ENV{SQITCH_CONFIG} = file qw(t user.conf);
    $sqitch = App::Sqitch->new;
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all user conf targets';
    is @targets, 4, 'Should have four user targets';
    is_deeply [ sort map { $_->name } @targets ], [
        'db:firebird:',
        'db:mysql:',
        'db:pg://postgres@localhost/thingies',
        'db:sqlite:my.db',
    ], 'Should have all the engine targets';

    # Load one with targets.
    $ENV{SQITCH_CONFIG} = file qw(t target.conf);
    $sqitch = App::Sqitch->new;
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all target conf targets';
    is @targets, 4, 'Should have three targets';
    is $targets[0]->name, 'db:pg:', 'Core engine should be default target';
    is_deeply [ sort map { $_->name } @targets ], [qw(db:pg: dev prod qa)],
        'Should have the core target plus the named targets';

    # Load one with engins and targets.
    $ENV{SQITCH_CONFIG} = file qw(t local.conf);
    $sqitch = App::Sqitch->new;
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all local conf targets';
    is @targets, 2, 'Should have two local targets';
    is $targets[0]->name, 'mydb', 'Core engine should be lead to default target';
    is_deeply [ sort map { $_->name } @targets ], [qw(devdb mydb)],
        'Should have the core target plus the named targets';

    # Mix up a core engine, engines, and targets.
    $ENV{SQITCH_CONFIG} = file qw(t engine.conf);
    $sqitch = App::Sqitch->new;
    ok @targets = $CLASS->all_targets(sqitch => $sqitch), 'Load all engine conf targets';
    is @targets, 3, 'Should have three engine conf targets';
    is_deeply [ sort map { $_->name } @targets ], [qw(db:mysql://root@/foo db:pg:try widgets)],
        'Should have the engine and target targets';
}


done_testing;
