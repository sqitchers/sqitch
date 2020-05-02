#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Path::Class qw(dir file);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use Test::MockModule;
use Test::Exception;
use Test::Warn;
use lib 't/lib';
use MockOutput;
use TestConfig;

my $CLASS = 'App::Sqitch::Command::rebase';
require_ok $CLASS or die;

isa_ok $CLASS, 'App::Sqitch::Command';
can_ok $CLASS, qw(
    target
    options
    configure
    new
    onto_change
    upto_change
    log_only
    execute
    deploy_variables
    revert_variables
    does
    _collect_deploy_vars
    _collect_revert_vars
);

ok $CLASS->does("App::Sqitch::Role::$_"), "$CLASS does $_"
    for qw(RevertDeployCommand ConnectingCommand ContextCommand);

is_deeply [$CLASS->options], [qw(
    onto-change|onto=s
    upto-change|upto=s
    revised
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
    y
)], 'Options should be correct';

warning_is {
    Getopt::Long::Configure(qw(bundling pass_through));
    ok Getopt::Long::GetOptionsFromArray(
        [], {}, App::Sqitch->_core_opts, $CLASS->options,
    ), 'Should parse options';
} undef, 'Options should not conflict with core options';

my $config = TestConfig->new(
    'core.engine'    => 'sqlite',
    'core.top_dir'   => dir(qw(t sql))->stringify,
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
);
ok my $sqitch = App::Sqitch->new(config => $config),
    'Load a sqitch sqitch object';

##############################################################################
# Test configure().
is_deeply $CLASS->configure($config, {}), {
    no_prompt     => 0,
    verify        => 0,
    mode          => 'all',
    prompt_accept => 1,
    _params       => [],
    _cx           => [],
}, 'Should have empty default configuration with no config or opts';

is_deeply $CLASS->configure($config, {
    set  => { foo => 'bar' },
}), {
    no_prompt        => 0,
    prompt_accept    => 1,
    verify           => 0,
    mode             => 'all',
    deploy_variables => { foo => 'bar' },
    revert_variables => { foo => 'bar' },
    _params          => [],
    _cx              => [],
}, 'Should have set option';

is_deeply $CLASS->configure($config, {
    y           => 1,
    set_deploy  => { foo => 'bar' },
    log_only    => 1,
    verify      => 1,
    mode        => 'tag',
}), {
    mode             => 'tag',
    no_prompt        => 1,
    prompt_accept    => 1,
    deploy_variables => { foo => 'bar' },
    verify           => 1,
    log_only         => 1,
    _params          => [],
    _cx              => [],
}, 'Should have mode, deploy_variables, verify, no_prompt, and log_only';

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
    my $config = TestConfig->new(
        'core.engine'      => 'sqlite',
        'deploy.variables' => { foo => 'bar', hi => 21 },
    );

    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        verify        => 0,
        mode          => 'all',
        prompt_accept => 1,
        _params       => [],
        _cx           => [],
    }, 'Should have deploy configuration';

    # Try setting variables.
    is_deeply $CLASS->configure($config, {
        onto_change => 'whu',
        set         => { foo => 'yo', yo => 'stellar' },
    }), {
        mode             => 'all',
        no_prompt        => 0,
        prompt_accept    => 1,
        verify           => 0,
        deploy_variables => { foo => 'yo', yo => 'stellar' },
        revert_variables => { foo => 'yo', yo => 'stellar' },
        onto_change      => 'whu',
        _params          => [],
        _cx              => [],
    }, 'Should have merged variables';
    is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

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
    }, 'Should have no_prompt true';

    # Rebase option takes precendence
    $config->update(
        'rebase.no_prompt'     => 0,
        'rebase.prompt_accept' => 1,
        'rebase.verify'        => 0,
        'rebase.mode'          => 'change',
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 0,
        mode          => 'change',
        _params       => [],
        _cx           => [],
    }, 'Should have false no_prompt, verify, and true prompt_accept from rebase config';

    $config->update(
        'revert.no_prompt'     => undef,
        'revert.prompt_accept' => undef,
        'rebase.verify'        => undef,
        'rebase.mode'          => undef,
        'rebase.no_prompt'     => 1,
        'rebase.prompt_accept' => 0,
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 1,
        prompt_accept => 0,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have true no_prompt, verify, and false prompt_accept from rebase from deploy';

    # But option should override.
    is_deeply $CLASS->configure($config, {y => 0, verify => 0, mode => 'all'}), {
        no_prompt     => 0,
        verify        => 0,
        mode          => 'all',
        prompt_accept => 0,
        _params       => [],
        _cx           => [],
    }, 'Should have no_prompt, prompt_accept false and mode all again';

    $config->update(
        'revert.no_prompt'     => 0,
        'revert.prompt_accept' => 1,
        'rebase.no_prompt'     => undef,
        'rebase.prompt_accept' => undef,
    );
    is_deeply $CLASS->configure($config, {}), {
        no_prompt     => 0,
        prompt_accept => 1,
        verify        => 1,
        mode          => 'tag',
        _params       => [],
        _cx           => [],
    }, 'Should have no_prompt false and prompt_accept true for revert config';

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
# Test accessors.
isa_ok my $rebase = $CLASS->new(
    sqitch   => $sqitch,
    target => 'foo',
), $CLASS, 'new status with target';
is $rebase->target, 'foo', 'Should have target "foo"';

isa_ok $rebase = $CLASS->new(sqitch => $sqitch), $CLASS;
is $rebase->target,      undef, 'Should have undef target';
is $rebase->onto_change, undef, 'onto_change should be undef';
is $rebase->upto_change, undef, 'upto_change should be undef';

# Mock the engine interface.
my $mock_engine = Test::MockModule->new('App::Sqitch::Engine::sqlite');
my @dep_args;
$mock_engine->mock(deploy => sub { shift; @dep_args = @_ });
my @rev_args;
$mock_engine->mock(revert => sub { shift; @rev_args = @_ });
my @vars;
$mock_engine->mock(set_variables => sub { shift; push @vars => [@_] });
my $common_ancestor_id;
$mock_engine->mock(planned_deployed_common_ancestor_id => sub { return $common_ancestor_id; });

##############################################################################
# Test _collect_deploy_vars and _collect_revert_vars.
$config->replace(
    'core.engine'    => 'sqlite',
    'core.top_dir'   => dir(qw(t sql))->stringify,
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
);
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $rebase->_collect_deploy_vars($target) }, {},
    'Should collect no variables for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {},
    'Should collect no variables for revert';

# Add core variables.
$config->update('core.variables' => { prefix => 'widget', priv => 'SELECT' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core deploy vars for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'SELECT',
}, 'Should collect core revert vars for revert';

# Add deploy variables.
$config->update('deploy.variables' => { dance => 'salsa', priv => 'UPDATE' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars for deploy';

is_deeply { $rebase->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Should override core vars with deploy vars for revert';

# Add revert variables.
$config->update('revert.variables' => { dance => 'disco', lunch => 'pizza' });
$target = App::Sqitch::Target->new(sqitch => $sqitch);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'salsa',
}, 'Deploy vars should be unaffected by revert vars';
is_deeply { $rebase->_collect_revert_vars($target) }, {
    prefix => 'widget',
    priv   => 'UPDATE',
    dance  => 'disco',
    lunch  => 'pizza',
}, 'Should override deploy vars with revert vars for revert';

# Add engine variables.
$config->update('engine.pg.variables' => { lunch => 'burrito', drink => 'whiskey', priv => 'UP' });
my $uri = URI::db->new('db:pg:');
$target = App::Sqitch::Target->new(sqitch => $sqitch, uri => $uri);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override deploy vars with engine vars for deploy';
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'whiskey',
}, 'Should override rebase vars with engine vars for revert';

# Add target variables.
$config->update('target.foo.variables' => { drink => 'scotch', status => 'winning' });
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'winning',
}, 'Should override engine vars with deploy vars for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {
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
$rebase = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'oregano',
}, 'Should override target vars with --set vars for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {
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
$rebase = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'basil',
    color  => 'black',
}, 'Should override --set vars with --set-deploy variables for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {
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
$rebase = $CLASS->new(
    sqitch => $sqitch,
    %{ $CLASS->configure($config, { %opts }) },
);
$target = App::Sqitch::Target->new(sqitch => $sqitch, name => 'foo', uri => $uri);
is_deeply { $rebase->_collect_deploy_vars($target) }, {
    prefix => 'widget',
    priv   => 'UP',
    dance  => 'salsa',
    lunch  => 'burrito',
    drink  => 'scotch',
    status => 'tired',
    herb   => 'basil',
    color  => 'black',
}, 'Should not override --set vars with --set-revert variables for deploy';
is_deeply { $rebase->_collect_revert_vars($target) }, {
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
    'core.top_dir'   => dir(qw(t sql))->stringify,
    'core.plan_file' => file(qw(t sql sqitch.plan))->stringify,
);
$rebase = $CLASS->new( sqitch => $sqitch);

##############################################################################
# Test execute().
my $mock_cmd = Test::MockModule->new($CLASS);
my $orig_method;
$mock_cmd->mock(parse_args => sub {
    my @ret = shift->$orig_method(@_);
    $target = $ret[0][0];
    @ret;
});
$orig_method = $mock_cmd->original('parse_args');

ok $rebase->execute('@alpha'), 'Execute to "@alpha"';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@vars, [[], []],
    'No vars should have been passed through to the engine';
is_deeply \@rev_args, ['@alpha'],
    '"@alpha" should be passed to the engine revert';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass a target.
@vars = ();
ok $rebase->execute('db:sqlite:yow'), 'Execute with target';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@rev_args, [undef],
    'undef should be passed to the engine revert';
is_deeply \@vars, [[], []],
    'No vars should have been passed through to the engine';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass both.
@vars = ();
ok $rebase->execute('db:sqlite:yow', 'widgets'), 'Execute with onto and target';
is_deeply \@dep_args, [undef, 'all'],
    'undef, and "all" should be passed to the engine deploy';
is_deeply \@rev_args, ['widgets'],
    '"widgets" should be passed to the engine revert';
is_deeply \@vars, [[], []],
    'No vars should have been passed through to the engine';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass all three!
@vars = ();
ok $rebase->execute('db:sqlite:yow', 'roles', 'widgets'),
    'Execute with three args';
is_deeply \@dep_args, ['widgets', 'all'],
    '"widgets", and "all" should be passed to the engine deploy';
is_deeply \@rev_args, ['roles'],
    '"roles" should be passed to the engine revert';
is_deeply \@vars, [[], []],
    'No vars should have been passed through to the engine';
ok !$target->engine->no_prompt, 'Engine should prompt';
ok !$target->engine->log_only, 'Engine should no be log only';
is $target->name, 'db:sqlite:yow', 'The target name should be as passed';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Pass no args.
@vars = @dep_args = @rev_args = ();
ok $rebase->execute, 'Execute';
is_deeply \@dep_args, [undef, 'all'],
    'undef and "all" should be passed to the engine deploy';
is_deeply \@rev_args, [undef],
    'undef and = should be passed to the engine revert';
is_deeply \@vars, [[], []],
    'No vars should have been passed through to the engine';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Test --revised
$common_ancestor_id = '42';
isa_ok $rebase = $CLASS->new(
    target           => 'db:sqlite:lolwut',
    no_prompt        => 1,
    log_only         => 1,
    verify           => 1,
    sqitch           => $sqitch,
    revised          => 1,
), $CLASS, 'Object with to and variables';

@vars = @dep_args = @rev_args = ();
ok $rebase->execute, 'Execute again';
is $target->name, 'db:sqlite:lolwut', 'Target name should be from option';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
ok $target->engine->with_verify, 'Engine should verify';
is_deeply \@rev_args, [$common_ancestor_id], 'the common ancestor id should be passed to the engine revert';

# Mix it up with options.
isa_ok $rebase = $CLASS->new(
    target           => 'db:sqlite:lolwut',
    no_prompt        => 1,
    log_only         => 1,
    verify           => 1,
    sqitch           => $sqitch,
    mode             => 'tag',
    onto_change      => 'foo',
    upto_change      => 'bar',
    deploy_variables => { foo => 'bar', one => 1 },
    revert_variables => { hey => 'there' },
), $CLASS, 'Object with to and variables';

@vars = @dep_args = @rev_args = ();
ok $rebase->execute, 'Execute again';
is $target->name, 'db:sqlite:lolwut', 'Target name should be from option';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
ok $target->engine->with_verify, 'Engine should verify';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is_deeply \@rev_args, ['foo'], '"foo" and 1 should be passed to the engine revert';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_warn, [], 'Should have no warnings';

# Make sure we get warnings for too many things.
@dep_args = @rev_args, @vars = ();
ok $rebase->execute('db:sqlite:yow', 'roles', 'widgets'),
    'Execute with three args';
is $target->name, 'db:sqlite:lolwut', 'Target name should be from option';
ok $target->engine->no_prompt, 'Engine should be no_prompt';
ok $target->engine->log_only, 'Engine should be log_only';
ok $target->engine->with_verify, 'Engine should verify';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is_deeply \@rev_args, ['foo'], '"foo" and 1 should be passed to the engine revert';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_warn, [[__x(
    'Too many targets specified; connecting to {target}',
    target => 'db:sqlite:lolwut',
)], [__x(
    'Too many changes specified; rebasing onto "{onto}" up to "{upto}"',
    onto => 'foo',
    upto => 'bar',
)]], 'Should have two warnings';

# Make sure we get an exception for unknown args.
throws_ok { $rebase->execute(qw(greg)) } 'App::Sqitch::X',
    'Should get an exception for unknown arg';
is $@->ident, 'rebase', 'Unknow arg ident should be "rebase"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    1,
    arg => 'greg',
), 'Should get an exeption for two unknown arg';

throws_ok { $rebase->execute(qw(greg jon)) } 'App::Sqitch::X',
    'Should get an exception for unknown args';
is $@->ident, 'rebase', 'Unknow args ident should be "rebase"';
is $@->message, __nx(
    'Unknown argument "{arg}"',
    'Unknown arguments: {arg}',
    2,
    arg => 'greg, jon',
), 'Should get an exeption for two unknown args';

# If nothing is deployed, or we are already at the revert target, the revert
# should be skipped.
@dep_args = @rev_args = @vars = ();
$mock_engine->mock(revert => sub { hurl { ident => 'revert', message => 'foo', exitval => 1 } });
ok $rebase->execute, 'Execute once more';
is_deeply \@dep_args, ['bar', 'tag'],
    '"bar", "tag", and 1 should be passed to the engine deploy';
is @vars, 2, 'Variables should have been passed to the engine twice';
is_deeply { @{ $vars[0] } }, { hey => 'there' },
    'The revert vars should have been passed first';
is_deeply { @{ $vars[1] } }, { foo => 'bar', one => 1 },
    'The deploy vars should have been next';
is_deeply +MockOutput->get_info, [['foo']],
    'Should have emitted info for non-fatal revert exception';

# Should die for fatal, unknown, or confirmation errors.
for my $spec (
    [ confirm => App::Sqitch::X->new(ident => 'revert:confirm', message => 'foo', exitval => 1) ],
    [ fatal   => App::Sqitch::X->new(ident => 'revert', message => 'foo', exitval => 2) ],
    [ unknown => bless { } => __PACKAGE__ ],
) {
    $mock_engine->mock(revert => sub { die $spec->[1] });
    throws_ok { $rebase->execute } ref $spec->[1],
        "Should rethrow $spec->[0] exception";
}

done_testing;
