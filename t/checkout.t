#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use utf8;
use Path::Class qw(dir file);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Test::MockModule;
use Test::Exception;
use Test::Warn;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::checkout';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    log_only
    lock_timeout
    execute
    deploy_variables
    revert_variables
    _collect_deploy_vars
    _collect_revert_vars
    does
);

ok $CLASS->does("App::Sqitch::Role::$_"), "$CLASS does $_"
    for qw(RevertDeployCommand ConnectingCommand ContextCommand);

is_deeply [$CLASS->options], [qw(
    plan-file|f=s
    top-dir=s
    registry=s
    client|db-client=s
    db-name|d=s
    db-user|db-username|u=s
    db-host|h=s
    db-port|p=i
    target|t=s
    mode=s
    verify!
    set|s=s%
    set-deploy|e=s%
    set-revert|r=s%
    log-only
    lock-timeout=i
    y
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';

ok my $sqitch = App::Sqitch->new(
    config => TestConfig->new(
        'core.engine'    => 'sqlite',
        'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
        'core.top_dir'   => dir(qw(t sql))->stringify,
    ),
), 'Load a sqitch object';

my $config = $sqitch->config;

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {
    no_prompt     => 0,
    prompt_accept => 1,
    verify        => 0,
    mode          => 'all',
    _params       => [],
    _cx           => [],
}, 'Check default configuration';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
}), {
    verify           => 0,
    no_prompt        => 0,
    prompt_accept    => 1,
    mode             => 'all',
    deploy_variables => { foo => 'bar' },
    revert_variables => { foo => 'bar' },
    _params       => [],
    _cx           => [],
}, 'Should have set option';

is_deeply $CLASS->configure($config, {
    y            => 1,
    set_deploy   => { foo => 'bar' },
    log_only     => 1,
    lock_timeout => 30,
    verify       => 1,
    mode         => 'tag',
}), {
    mode             => 'tag',
    no_prompt        => 1,
    prompt_accept    => 1,
    deploy_variables => { foo => 'bar' },
    verify           => 1,
    log_only         => 1,
    lock_timeout     => 30,
    _params          => [],
    _cx              => [],
}, 'Should have mode, deploy_variables, verify, no_prompt, log_only, & lock_timeout';

is_deeply $CLASS->configure($config, {
    y           => 0,
    set_revert  => { foo => 'bar' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    revert_variables => { foo => 'bar' },
    _params          => [],
    _cx              => [],
}, 'Should have set_revert option and no_prompt false';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { foo => 'dep', hi => 'you' },
    set_revert => { foo => 'rev', hi => 'me' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    deploy_variables => { foo => 'dep', hi => 'you' },
    revert_variables => { foo => 'rev', hi => 'me' },
    _params          => [],
    _cx              => [],
}, 'set_deploy and set_revert should overrid set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { hi => 'me' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', hi => 'me' },
    _params          => [],
    _cx              => [],
}, 'set_deploy and set_revert should merge with set';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
    set_deploy => { hi => 'you' },
    set_revert => { my => 'yo' },
}), {
    mode             => 'all',
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    deploy_variables => { foo => 'bar', hi => 'you' },
    revert_variables => { foo => 'bar', my => 'yo' },
    _params          => [],
    _cx              => [],
}, 'set_revert should merge with set_deploy';

CONFIG: {
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 0,
        mode          => 'all',
        _params       => [],
        _cx           => [],
    }, 'Should have deploy configuration';

    # Try setting variables.
    is_deeply $CLASS->configure($config, {
        set         => { foo => 'yo', yo => 'stellar' },
    }), {
        mode             => 'all',
        no_prompt        => 0,
        prompt_accept    => 1,
        verify           => 0,
        deploy_variables => { foo => 'yo', yo => 'stellar' },
        revert_variables => { foo => 'yo', yo => 'stellar' },
        _params          => [],
        _cx              => [],
    }, 'Should have merged variables';

    # Make sure we can override mode, prompting, and verify.
    $config->replace(
        'core.engine'          => 'sqlite',
        'revert.no_prompt'     => 1,
        'revert.prompt_accept' => 0,
        'deploy.verify'        => 1,
        'deploy.mode'          => 'tag',
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 1,
        prompt_accept => 0,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have no_prompt and prompt_accept from revert config';

    # Checkout option takes precendence
    $config->update(
        'checkout.no_prompt'     => 0,
        'checkout.prompt_accept' => 1,
        'checkout.verify'        => 0,
        'checkout.mode'          => 'change',
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 0,
        mode          => 'change',
        _params       => [],
        _cx           => [],
    }, 'Should have false log_only, verify, true prompt_accept from checkout config';

    $config->update(
        'checkout.no_prompt' => 1,
        map { $_ => undef } qw(
            revert.no_prompt
            revert.prompt_accept
            checkout.verify
            checkout.mode
        )
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 1,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have log_only, prompt_accept true from checkout and verify from deploy';

    # But option should override.
    is_deeply $CLASS->configure($config, {y => 0, verify => 0, mode => 'all'}), {
        no_prompt     => 0,
        verify        => 0,
        mode          => 'all',
        prompt_accept => 1,
        _params       => [],
        _cx           => [],
    }, 'Should have log_only false and mode all again';

    $config->update(
        'checkout.no_prompt'     => 0,
        'checkout.prompt_accept' => 1,
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have log_only false for false config';

    is_deeply $CLASS->configure($config, {y => 1}), {
        no_prompt     => 1,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have no_prompt true with -y';
}

##############################################################################
# Test _collect_deploy_vars and _collect_revert_vars.
$config->replace(
    'core.engine'    => 'sqlite',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);
my $checkout = $CLASS->new( sqitch => $sqitch);
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $checkout->_collect_deploy_vars($target) }, {},
    'Should collect no variables for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {},
    'Should collect no variables for revert';

# Add core variables.
$config->update('core.variables' => { prefix => 'widget', priv => 'SELECT' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core deploy vars for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core revert vars for revert';

# Add deploy variables.
$config->update('deploy.variables' => { dance => 'salsa', priv => 'UPDATE' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars for deploy';

is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars for revert';

# Add revert variables.
$config->update('revert.variables' => { dance => 'disco', lunch => 'pizza' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Deploy vars should be unaffected by revert vars';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'pizza',
}, 'Should override deploy vars with revert vars for revert';

# Add engine variables.
$config->update('engine.pg.variables' => { lunch => 'burrito', drink => 'whiskey', priv => 'UP' });
my $uri = URI::db->new('db:pg:');
$target = App::Sqitch::Target->new(sqitch => $sqitch, uri => $uri);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override deploy vars with engine vars for deploy';
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override checkout vars with engine vars for revert';

# Add target variables.
$config->update('target.foo.variables' => { drink => 'scotch', status => 'winning' });
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override engine vars with deploy vars for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override engine vars with target vars for revert';

# Add --set variables.
my %opts = (
    set => { status => 'tired', herb => 'oregano' },
);
$checkout = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should override target vars with --set vars for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should override target vars with --set variables for revert';

# Add --set-deploy-vars
$opts{set_deploy} = { herb => 'basil', color => 'black' };
$checkout = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'basil',
    color  => 'black',
}, 'Should override --set vars with --set-deploy variables for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should not override --set vars with --set-deploy variables for revert';

# Add --set-revert-vars
$opts{set_revert} = { herb => 'garlic', color => 'red' };
$checkout = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $checkout->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'basil',
    color  => 'black',
}, 'Should not override --set vars with --set-revert variables for deploy';
is_deeply { $checkout->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'disco',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'garlic',
    color  => 'red',
}, 'Should override --set vars with --set-revert variables for revert';

$config->replace(
    'core.engine'    => 'sqlite',
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
    'core.top_dir'   => dir(qw(t sql))->stringify,
);

##############################################################################
# Test execute().
my $mock_sqitch = Test::MockModule->new(ref $sqitch);
my (@probe_args, $probed, $orig_method);
$mock_sqitch->mock(probe => sub { shift; @probe_args = @_; $probed });
my $mock_cmd = Test::MockModule->new($CLASS);
$mock_cmd->mock(parse_args => sub {
    my @ret = shift->$orig_method(@_);
    $target = $ret[1][0];
    @ret;
});
$orig_method = $mock_cmd->original('parse_args');

my @run_args;
$mock_sqitch->mock(run => sub { shift; @run_args = @_ });

# Try rebasing to the current branch.
isa_ok $checkout = App::Sqitch::Command->load({
    sqitch  => $sqitch,
    command => 'checkout',
    config  => $config,
}), $CLASS, 'checkout command';
my $client = $checkout->client;

$probed = 'fixdupes';
throws_ok { $checkout->execute($probed) } 'App::Sqitch::X',
    'Should get an error current branch';
is $@->ident, 'checkout', 'Current branch error ident should be "checkout"';
is $@->message, __x('Already on branch {branch}', branch => $probed),
    'Should get proper error for current branch error';
is_deeply \@probe_args, [$client, qw(rev-parse --abbrev-ref HEAD)],
    'The proper args should have been passed to rev-parse';
@probe_args = ();

# Try a plan with nothing in common with the current branch's plan.
my (@capture_args, $captured);
$mock_sqitch->mock(capture => sub { shift; @capture_args = @_; $captured });
$captured = q{%project=sql

foo 2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>
bar 2012-07-16T17:25:07Z Barack Obama <potus@whitehouse.gov>
};

throws_ok { $checkout->execute('main') } 'App::Sqitch::X',
    'Should get an error for plans without a common change';
is $@->ident, 'checkout',
    'The no common change error ident should be "checkout"';
is $@->message, __x(
    'Branch {branch} has no changes in common with current branch {current}',
    branch  => 'main',
    current => $probed,
), 'The no common change error message should be correct';

# Show usage when no branch name specified.
my @args;
$mock_cmd->mock(usage => sub { @args = @_; die 'USAGE' });
throws_ok { $checkout->execute } qr/USAGE/,
    'No branch arg should yield usage';
is_deeply \@args, [$checkout], 'No args should be passed to usage';

@args = ();
throws_ok { $checkout->execute('') } qr/USAGE/,
    'Empty branch arg should yield usage';
is_deeply \@args, [$checkout], 'No args should be passed to usage';
$mock_cmd->unmock('usage');

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my (@dep_args, @dep_changes);
$mock_engine->mock(deploy => sub {
    @dep_changes = map { $_->name } shift->plan->changes;
    @dep_args = @_;
});

my (@rev_args, @rev_changes);
$mock_engine->mock(revert => sub {
    @rev_changes = map { $_->name } shift->plan->changes;
    @rev_args = @_;
 });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });

# Load up the plan file without decoding and change the plan.
$captured = file(qw(t sql sqitch.plan))->slurp;
{
    no utf8;
    $captured =~ s/widgets/thingíes/;
}

# Checkout with options.
isa_ok $checkout = $CLASS->new(
    log_only         => 1,
    lock_timeout     => 30,
    verify           => 1,
    sqitch           => $sqitch,
    mode             => 'tag',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

ok $checkout->execute('main'), 'Checkout main';
is_deeply \@probe_args, [$client, qw(rev-parse --abbrev-ref HEAD)],
    'The proper args should again have been passed to rev-parse';
is_deeply \@capture_args, [$client, 'show', 'main:'
    . File::Spec->catfile(File::Spec->curdir, $checkout->default_target->plan_file)
], 'Should have requested the plan file contents as of main';
is_deeply \@run_args, [$client, qw(checkout main)], 'Should have checked out other branch';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

is_deeply +MockOutput->get_info, [[__x(
    'Last change before the branches diverged: {last_change}',
    last_change => 'users @alpha',
)]], 'Should have emitted info identifying the last common change';

# Did it revert?
is_deeply \@rev_args, [$checkout->default_target->plan->get('users')->id, 1, undef],
    '"users" ID and 1 should be passed to the engine revert';
is_deeply \@rev_changes, [qw(roles users widgets)],
    'Should have had the current changes for revision';

# Did it deploy?
is_deeply \@dep_args, [undef, 'tag'],
    'undef, "tag", and 1 should be passed to the engine deploy';
is_deeply \@dep_changes, [qw(roles users thingíes)],
    'Should have had the other branch changes (decoded) for deploy';

ok $target->engine->with_verify, 'Engine should verify';
ok $target->engine->log_only, 'The engine should be set to log_only';
is $target->engine->lock_timeout, 30, 'The lock timeout should be set to 30';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';

# Try passing a target.
@vars = ();
ok $checkout->execute('main', 'db:sqlite:foo'), 'Checkout main with target';
is $target->name, 'db:sqlite:foo', 'Target should be passed to engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# If nothing is deployed, or we are already at the revert target, the revert
# should be skipped.
isa_ok $checkout = $CLASS->new(
    target           => 'db:sqlite:hello',
    log_only         => 0,
    verify           => 0,
    sqitch           => $sqitch,
    mode             => 'tag',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

$mock_engine->mock(revert => sub { hurl { ident => 'revert', message => 'foo', exitval => 1 } });
@dep_args = @rev_args = @vars = ();
ok $checkout->execute('main'), 'Checkout main again';
is $target->name, 'db:sqlite:hello', 'Target should be passed to engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Did it deploy?
ok !$target->engine->log_only, 'The engine should not be set to log_only';
is $target->engine->lock_timeout, App::Sqitch::Engine::default_lock_timeout(),
    'The lock timeout should be set to the default';
ok !$target->engine->with_verify, 'The engine should not be set with_verfy';
is_deeply \@dep_args, [undef, 'tag'],
    'undef, "tag", and 1 should be passed to the engine deploy again';
is_deeply \@dep_changes, [qw(roles users thingíes)],
    'Should have had the other branch changes (decoded) for deploy again';
is @vars, 2, 'Variables should again have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should again have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should again have been next';

# Should get a warning for two targets.
ok $checkout->execute('main', 'db:sqlite:'), 'Checkout main again with target';
is $target->name, 'db:sqlite:hello', 'Target should be passed to engine';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => 'db:sqlite:hello',
)]], 'Should have warning about two targets';

# Make sure we get an exception for unknown args.
throws_ok { $checkout->execute(qw(main greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'checkout', 'Unknow arg ident should be "checkout"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    1,
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $checkout->execute(qw(main greg widgets)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'checkout', 'Unknow args ident should be "checkout"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    2,
    arg => 'greg, widgets',
), 'Should get an exeption for two unknown args';

# Should die for fatal, unknown, or confirmation errors.
for my $spec (
    [ confirm => App::Sqitch::X->new(ident => 'revert:confirm', message => 'foo', exitval => 1) ],
    [ fatal   => App::Sqitch::X->new(ident => 'revert', message => 'foo', exitval => 2) ],
    [ unknown => bless { } => __PACKAGE__ ],
) {
    $mock_engine->mock(revert => sub { die $spec->[1] });
    throws_ok { $checkout->execute('main') } ref $spec->[1],
        "Should rethrow $spec->[0] exception";
}


# Should die if running in strict mode.
ok $config = TestConfig->new(
    'revert.strict'    => 1
), 'Create strict config';
ok $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
throws_ok {
    $CLASS->new(
        sqitch           => $sqitch,
        ); }
    'App::Sqitch::X',
    'Cannot initialize command in strict mode.';

ok $config = TestConfig->new(
    'checkout.strict'    => 1
), 'Create strict config';
ok $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
throws_ok {
    $CLASS->new(
        sqitch           => $sqitch,
        ); }
    'App::Sqitch::X',
    'Cannot initialize command in strict mode.';

ok $config = TestConfig->new(
    'revert.strict'    => 1,
    'checkout.strict'  => 0
), 'Create strict config';
ok $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';
ok $CLASS->new(
    sqitch           => $sqitch,
    ),
   'Okay to initialize because checkout is not in strict mode';

done_testing;
