#!/usr/bin/perl -w

use strict;
use warnings;
use 5.010;
use utf8;
use Test::More tests => 187;
#use Test::More 'no_plan';
use App::Sqitch;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::Exception;
use Test::File::Contents;
use Test::NoWarnings;
use File::Path qw(remove_tree make_path);
use URI;
use lib 't/lib';
use MockOutput;

my $exe_ext = $^O eq 'MSWin32' ? '.exe' : '';

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Command::init';
    use_ok $CLASS or die;
}

isa_ok $CLASS, 'App::Sqitch::Command', $CLASS;
chdir 't';

sub read_config($) {
    my $conf = App::Sqitch::Config->new;
    $conf->load_file(shift);
    $conf->data;
}

$ENV{SQITCH_CONFIG}        = 'nonexistent.conf';
$ENV{SQITCH_USER_CONFIG}   = 'nonexistent.user';
$ENV{SQITCH_SYSTEM_CONFIG} = 'nonexistent.sys';

##############################################################################
# Test options and configuration.
my $sqitch = App::Sqitch->new(
    options => { top_dir => dir('init.mkdir') },
);

isa_ok my $init = $CLASS->new(
    sqitch     => $sqitch,
    properties => { reworked_dir => dir('init.mkdir/reworked') },
), $CLASS, 'New init object';

can_ok $init, qw(
    uri
    properties
    options
    configure
);

is_deeply [$init->options], [qw(
    uri=s
    engine=s
    target=s
    plan-file=s
    registry=s
    client=s
    extension=s
    top-dir=s
    dir|d=s%
)], 'Options should be correct';

is_deeply $CLASS->configure({}, {}), { properties => {}},
    'Default config should contain empty properties';
is_deeply $CLASS->configure({}, { uri => 'http://example.com' }), {
    uri        => URI->new('http://example.com'),
    properties => {},
}, 'Should accept a URI in options';
ok my $config = $CLASS->configure({}, {
    uri                 => 'http://example.com',
    engine              => 'pg',
    top_dir             => 'top',
    plan_file           => 'my.plan',
    registry            => 'bats',
    client              => 'cli',
    extension           => 'ddl',
    target              => 'db:pg:foo',
    dir => {
        deploy          => 'dep',
        revert          => 'rev',
        verify          => 'ver',
        reworked        => 'wrk',
        reworked_deploy => 'rdep',
        reworked_revert => 'rrev',
        reworked_verify => 'rver',
    },
}), 'Get full config';

isa_ok $config->{uri}, 'URI', 'uri propertiy';
is_deeply $config->{properties}, {
        engine              => 'pg',
        top_dir             => 'top',
        plan_file           => 'my.plan',
        registry            => 'bats',
        client              => 'cli',
        extension           => 'ddl',
        target              => 'db:pg:foo',
        deploy_dir          => 'dep',
        revert_dir          => 'rev',
        verify_dir          => 'ver',
        reworked_dir        => 'wrk',
        reworked_deploy_dir => 'rdep',
        reworked_revert_dir => 'rrev',
        reworked_verify_dir => 'rver',
}, 'Should have properties';
isa_ok $config->{properties}{$_}, 'Path::Class::File', "$_ file attribute" for qw(
    plan_file
);
isa_ok $config->{properties}{$_}, 'Path::Class::Dir', "$_ directory attribute" for (
    'top_dir',
    'reworked_dir',
    map { ($_, "reworked_$_") } qw(deploy_dir revert_dir verify_dir)
);

# Make sure invalid directories are ignored.
throws_ok { $CLASS->new($CLASS->configure({}, {
    dir => { foo => 'bar' },
})) } 'App::Sqitch::X',  'Should fail on invalid directory name';
is $@->ident, 'init', 'Invalid directory ident should be "init"';
is $@->message, __x(
    'Unknown directory name: {prop}',
    prop => 'foo',
), 'The invalid directory messsage should be correct';

throws_ok { $CLASS->new($CLASS->configure({}, {
    dir => { foo => 'bar', cavort => 'ha' },
})) } 'App::Sqitch::X',  'Should fail on invalid directory names';
is $@->ident, 'init', 'Invalid directories ident should be "init"';
is $@->message, __x(
    'Unknown directory names: {props}',
    props => 'cavort, foo',
), 'The invalid properties messsage should be correct';

isa_ok my $target = $init->default_target, 'App::Sqitch::Target', 'default target';

##############################################################################
# Test make_directories_for.
can_ok $init, 'make_directories_for';
dir_not_exists_ok $target->top_dir;
dir_not_exists_ok $_ for $init->directories_for($target);

my $top_dir_string = $target->top_dir->stringify;
END { remove_tree $top_dir_string if -e $top_dir_string }

ok $init->make_directories_for($target), 'Make the directories';
dir_exists_ok $_ for $init->directories_for($target);

my $sep = dir('')->stringify;
my $dirs = $init->properties;
is_deeply +MockOutput->get_info, [
    [__x "Created {file}", file => $target->deploy_dir . $sep],
    [__x "Created {file}", file => $target->revert_dir . $sep],
    [__x "Created {file}", file => $target->verify_dir . $sep],
    [__x "Created {file}", file => $dirs->{reworked_dir}->subdir('deploy') . $sep],
    [__x "Created {file}", file => $dirs->{reworked_dir}->subdir('revert') . $sep],
    [__x "Created {file}", file => $dirs->{reworked_dir}->subdir('verify') . $sep],
], 'Each should have been sent to info';

# Do it again.
ok $init->make_directories_for($target), 'Make the directories again';
is_deeply +MockOutput->get_info, [], 'Nothing should have been sent to info';

# Delete one of them.
remove_tree $target->revert_dir->stringify;
ok $init->make_directories_for($target), 'Make the directories once more';
dir_exists_ok $target->revert_dir, 'revert dir exists again';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $target->revert_dir . $sep],
], 'Should have noted creation of revert dir';

remove_tree $top_dir_string;

# Handle errors.
FSERR: {
    # Make mkpath to insert an error.
    my $mock = Test::MockModule->new('File::Path');
    $mock->mock( mkpath => sub {
        my ($file, $p) = @_;
        ${ $p->{error} } = [{ $file => 'Permission denied yo'}];
        return;
    });

    throws_ok { $init->make_directories_for($target) } 'App::Sqitch::X',
        'Should fail on permission issue';
    is $@->ident, 'init', 'Permission error should have ident "init"';
    is $@->message, __x(
        'Error creating {path}: {error}',
        path  => $target->deploy_dir,
        error => 'Permission denied yo',
    ), 'The permission error should be formatted properly';
}

##############################################################################
# Test write_config().
can_ok $init, 'write_config';

my $write_dir = 'init.write';
make_path $write_dir;
END { remove_tree $write_dir }
chdir $write_dir;
END { chdir File::Spec->updir }
my $conf_file = $sqitch->config->local_file;

my $uri = URI->new('https://github.com/theory/sqitch/');

$sqitch = App::Sqitch->new;
ok $init = $CLASS->new(
    sqitch  => $sqitch,
), 'Another init object';
file_not_exists_ok $conf_file;
$target = $init->default_target;

# Write empty config.
ok $init->write_config, 'Write the config';
file_exists_ok $conf_file;
is_deeply read_config $conf_file, {
}, 'The configuration file should have no variables';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info';
my $top_dir    = File::Spec->curdir;
my $deploy_dir = File::Spec->catdir(qw(deploy));
my $revert_dir = File::Spec->catdir(qw(revert));
my $verify_dir   = File::Spec->catdir(qw(verify));
my $plan_file  = $target->top_dir->file('sqitch.plan')->cleanup->stringify;
file_contents_like $conf_file, qr{\Q[core]
	# engine = 
	# plan_file = $plan_file
	# top_dir = $top_dir
}m, 'All in core section should be commented-out';
unlink $conf_file;

# Set two options.
$sqitch = App::Sqitch->new;
ok $init = $CLASS->new( sqitch => $sqitch,  properties => { extension => 'foo' } ),
    'Another init object';
$target = $init->default_target;
ok $init->write_config, 'Write the config';
file_exists_ok $conf_file;
is_deeply read_config $conf_file, {
    'core.extension' => 'foo',
}, 'The configuration should have been written with the one setting';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info';

file_contents_like $conf_file, qr{
	# engine = 
	# plan_file = $plan_file
	# top_dir = $top_dir
}m, 'Other settings should be commented-out';

# Go again.
ok $init->write_config, 'Write the config again';
is_deeply read_config $conf_file, {
    'core.extension' => 'foo',
}, 'The configuration should be unchanged';
is_deeply +MockOutput->get_info, [
], 'Nothing should have been sent to info';

USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new;
    ok my $init = $CLASS->new( sqitch => $sqitch, properties => { extension => 'foo' }),
        'Make an init object with user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with a user conf';
    file_exists_ok $conf_file;
    is_deeply read_config $conf_file, {
        'core.extension' => 'foo',
    }, 'The configuration should just have core.top_dir';
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $conf_file]
    ], 'The creation should be sent to info again';
    file_contents_like $conf_file, qr{\Q
	# engine = 
	# plan_file = $plan_file
	# top_dir = $top_dir
}m, 'Other settings should be commented-out';
}

SYSTEMCONF: {
    # Delete the file and write with a system config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_SYSTEM_CONFIG} = file +File::Spec->updir, 'sqitch.conf';
    my $sqitch = App::Sqitch->new;
    ok my $init = $CLASS->new( sqitch => $sqitch, properties => { extension => 'foo' } ),
        'Make an init object with system config';
    ok $target = $init->default_target, 'Get target';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with a system conf';
    file_exists_ok $conf_file;
    is_deeply read_config $conf_file, {
        'core.extension' => 'foo',
        'core.engine' => 'pg',
    }, 'The configuration should have local and system config' or diag $conf_file->slurp;
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $conf_file]
    ], 'The creation should be sent to info again';

    my $plan_file  = $target->top_dir->file('sqitch.plan')->stringify;
    file_contents_like $conf_file, qr{\Q
	# plan_file = $plan_file
	# top_dir = migrations
}m, 'Other settings should be commented-out';
}

##############################################################################
# Now get it to write a bunch of other stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new;

ok $init = $CLASS->new(
    sqitch              => $sqitch,
    properties => {
        engine              => 'sqlite',
        top_dir             => dir('top'),
        plan_file           => file('my.plan'),
        registry            => 'bats',
        client              => 'cli',
        target              => 'db:sqlite:foo',
        extension           => 'ddl',
        deploy_dir          => dir('dep'),
        revert_dir          => dir('rev'),
        verify_dir          => dir('tst'),
        reworked_deploy_dir => dir('rdep'),
        reworked_revert_dir => dir('rrev'),
        reworked_verify_dir => dir('rtst'),
    }
), 'Create new init with sqitch non-default attributes';

ok $init->write_config, 'Write the config with core attrs';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info once more';

is_deeply read_config $conf_file, {
    'core.top_dir'             => 'top',
    'core.plan_file'           => 'my.plan',
    'core.deploy_dir'          => 'dep',
    'core.revert_dir'          => 'rev',
    'core.verify_dir'          => 'tst',
    'core.reworked_deploy_dir' => 'rdep',
    'core.reworked_revert_dir' => 'rrev',
    'core.reworked_verify_dir' => 'rtst',
    'core.extension'           => 'ddl',
    'core.engine'              => 'sqlite',
    'engine.sqlite.registry'   => 'bats',
    'engine.sqlite.client'     => 'cli',
    'engine.sqlite.target'     => 'db:sqlite:foo',
}, 'The configuration should have been written with core and engine values';

##############################################################################
# Now get it to write core.sqlite stuff with main options.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    options => {
        engine => 'sqlite',
        client => '/to/sqlite3',
        registry => 'foo',
        target  => 'bar',
    },
);

ok $init = $CLASS->new( sqitch => $sqitch ),
    'Create new init with sqitch with non-default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info yet again';

is_deeply read_config $conf_file, {
    'core.engine'            => 'sqlite',
    'engine.sqlite.client'   => '/to/sqlite3',
    'engine.sqlite.registry' => 'foo',
    'engine.sqlite.target'   => 'bar',
    'target.bar.uri'         => 'db:sqlite:',
}, 'Config should have been written with sqlite and target values';

# Try it with no options.
unlink $conf_file;
$sqitch = App::Sqitch->new(options => { engine => 'sqlite' });
ok $init = $CLASS->new( sqitch => $sqitch ),
    'Create new init with sqitch with default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info again again';
is_deeply read_config $conf_file, {
    'core.engine' => 'sqlite',
}, 'The configuration should have been written with only the engine var';

file_contents_like $conf_file, qr{^\Q# [engine "sqlite"]
	# target = db:sqlite:
	# registry = sqitch
	# client = sqlite3$exe_ext
}m, 'Engine section should be present but commented-out';

# Now build it with other config.
USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new(options => { engine => 'sqlite' });
    ok my $init = $CLASS->new( sqitch => $sqitch ),
        'Make an init with sqlite and user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with sqlite config';
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $conf_file]
    ], 'The creation should be sent to info once more';

    is_deeply read_config $conf_file, {
        'core.engine'         => 'sqlite',
    }, 'New config should have been written with sqlite values';

    file_contents_like $conf_file, qr{^\t\Q# client = /opt/local/bin/sqlite3\E\n}m,
        'Configured client should be included in a comment';
    file_contents_like $conf_file, qr/^\t# target = db:sqlite:my\.db\n/m,
        'Configured target should be included in a comment';
    file_contents_like $conf_file, qr/^\t# registry = meta\n/m,
        'Configured registry should be included in a comment';
}

##############################################################################
# Now get it to write engine.pg stuff.
unlink $conf_file;
$sqitch = App::Sqitch->new(
    options => {
        engine     => 'pg',
        client      => '/to/psql',
    },
);

ok $init = $CLASS->new( sqitch => $sqitch ),
    'Create new init with sqitch with more non-default engine attributes';
ok $init->write_config, 'Write the config with more engine attrs';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info one more time';

is_deeply read_config $conf_file, {
    'core.engine'    => 'pg',
    'engine.pg.client' => '/to/psql',
}, 'The configuration should have been written with client values' or diag $conf_file->slurp;

file_contents_like $conf_file, qr/^\t# registry = sqitch\n/m,
    'registry should be included in a comment';

# Try it with no config or options.
unlink $conf_file;
$sqitch = App::Sqitch->new(options => { engine => 'pg' });
ok $init = $CLASS->new( sqitch => $sqitch ),
    'Create new init with sqitch with default engine attributes';
ok $init->write_config, 'Write the config with engine attrs';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file]
], 'The creation should be sent to info again again again';
is_deeply read_config $conf_file, {
    'core.engine' => 'pg',
}, 'The configuration should have been written with only the engine var' or diag $conf_file->slurp;

file_contents_like $conf_file, qr{^\Q# [engine "pg"]
	# target = db:pg:
	# registry = sqitch
	# client = psql$exe_ext
}m, 'Engine section should be present but commented-out' or diag $conf_file->slurp;

USERCONF: {
    # Delete the file and write with a user config loaded.
    unlink $conf_file;
    local $ENV{SQITCH_USER_CONFIG} = file +File::Spec->updir, 'user.conf';
    my $sqitch = App::Sqitch->new(options => { engine => 'pg' });
    ok my $init = $CLASS->new( sqitch  => $sqitch ),
        'Make an init with pg and user config';
    file_not_exists_ok $conf_file;
    ok $init->write_config, 'Write the config with pg config';
    is_deeply +MockOutput->get_info, [
        [__x 'Created {file}', file => $conf_file]
    ], 'The pg config creation should be sent to info';

    is_deeply read_config $conf_file, {
        'core.engine'      => 'pg',
    }, 'The configuration should have been written with pg options' or diag $conf_file->slurp;

    file_contents_like $conf_file, qr/^\t# registry = meta\n/m,
        'Configured registry should be in a comment';
    file_contents_like $conf_file,
        qr{^\t# target = db:pg://postgres\@localhost/thingies\n}m,
        'Configured target should be in a comment';
}

##############################################################################
# Test write_plan().
can_ok $init, 'write_plan';
$target = $init->default_target;
$plan_file = $target->plan_file;
file_not_exists_ok $plan_file, 'Plan file should not yet exist';
ok $init->write_plan( project => 'nada' ), 'Write the plan file';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $plan_file]
], 'The plan creation should be sent to info';
file_exists_ok $plan_file, 'Plan file should now exist';
file_contents_is $plan_file,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION() . "\n" .
    '%project=nada' . "\n\n",
 'The contents should be correct';

# Make sure we don't overwrite the file when initializing again.
ok $init->write_plan( project => 'nada' ), 'Write the plan file again';
file_exists_ok $plan_file, 'Plan file should still exist';
file_contents_is $plan_file,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION() . "\n" .
    '%project=nada' . "\n\n",
 'The contents should be identical';

# Make sure we get an error trying to initalize a different plan.
throws_ok { $init->write_plan( project => 'oopsie' ) } 'App::Sqitch::X',
    'Should get an error initialing a different project';
is $@->ident, 'init', 'Initialization error ident should be "init"';
is $@->message, __x(
    'Cannot initialize because project "{project}" already initialized in {file}',
    project => 'nada',
    file    => $plan_file,
), 'Initialzation error message should be correct';

# Write a different file.
my $fh = $plan_file->open('>:utf8_strict') or die "Cannot open $plan_file: $!\n";
$fh->say('# testing 1, 2, 3');
$fh->close;

# Try writing again.
throws_ok { $init->write_plan( project => 'foofoo' ) } 'App::Sqitch::X',
    'Should get an error initialzing a non-plan file';
is $@->ident, 'init', 'Non-plan file error ident should be "init"';
is $@->message, __x(
    'Cannot initialize because {file} already exists and is not a valid plan file',
    file    => $plan_file,
), 'Non-plan file error message should be correct';
file_contents_like $plan_file, qr/testing 1, 2, 3/,
    'The file should not be overwritten';

# Make sure a URI gets written, if present.
$plan_file->remove;
$sqitch = App::Sqitch->new(options => { top_dir => dir('plan.dir') });
END { remove_tree dir('plan.dir')->stringify };
ok $init = $CLASS->new(
    sqitch => $sqitch,
    uri    => $uri,
), 'Create new init with sqitch with project and URI';
$target = $init->default_target;
$plan_file = $target->plan_file;
ok $init->write_plan( project => 'howdy', uri => $init->uri ), 'Write the plan file again';
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $plan_file->dir . $sep],
    [__x 'Created {file}', file => $plan_file]
], 'The plan creation should be sent to info againq';
file_exists_ok $plan_file, 'Plan file should again exist';
file_contents_is $plan_file,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION() . "\n" .
    '%project=howdy' . "\n" .
    '%uri=' . $uri->canonical . "\n\n",
    'The plan should include the project and uri pragmas';

##############################################################################
# Test _validate_project().
can_ok $init, '_validate_project';
NOPROJ: {
    # Test handling of no command.
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(usage => sub { @args = @_; die 'USAGE' });
    throws_ok { $CLASS->_validate_project }
        qr/USAGE/, 'No project should yield usage';
    is_deeply \@args, [$CLASS], 'No args should be passed to usage';
}

# Test invalid project names.
my @bad_names = (
    '^foo',     # No leading punctuation
    'foo^',     # No trailing punctuation
    'foo^6',    # No trailing punctuation+digit
    'foo^666',  # No trailing punctuation+digits
    '%hi',      # No leading punctuation
    'hi!',      # No trailing punctuation
    'foo@bar',  # No @ allowed at all
    'foo:bar',  # No : allowed at all
    '+foo',     # No leading +
    '-foo',     # No leading -
    '@foo',     # No leading @
);
for my $bad (@bad_names) {
    throws_ok { $init->_validate_project($bad) } 'App::Sqitch::X',
        qq{Should get error for invalid project name "$bad"};
    is $@->ident, 'init', qq{Bad project "$bad" ident should be "init"};
    is $@->message, __x(
        qq{invalid project name "{project}": project names must not }
        . 'begin with punctuation, contain "@", ":", "#", or blanks, or end in '
        . 'punctuation or digits following punctuation',
        project => $bad
    ), qq{Bad project "$bad" error message should be correct};
}

##############################################################################
# Bring it all together, yo.
$conf_file->remove;
$plan_file->remove;
ok $init->execute('foofoo'), 'Execute!';

# Should have directories.
for my $attr (map { "$_\_dir"} qw(top deploy revert verify)) {
    dir_exists_ok $target->$attr;
}

# Should have config and plan.
file_exists_ok $conf_file;
file_exists_ok $plan_file;

# Should have the output.
my @dir_messages = map {
    [__x 'Created {file}', file => $target->$_ . $sep]
} map { "$_\_dir" } qw(deploy revert verify);
is_deeply +MockOutput->get_info, [
    [__x 'Created {file}', file => $conf_file],
    [__x 'Created {file}', file => $plan_file],
    @dir_messages,
], 'Should have status messages';

file_contents_is $plan_file,
    '%syntax-version=' . App::Sqitch::Plan::SYNTAX_VERSION() . "\n" .
    '%project=foofoo' . "\n" .
    '%uri=' . $uri->canonical . "\n\n",
    'The plan should have the --project name';
