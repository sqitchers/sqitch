#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 56;

#use Test::More 'no_plan';
use App::Sqitch;
use Test::NoWarnings;
use Test::Exception;
use Test::Dir;
use Test::File qw(file_not_exists_ok file_exists_ok);
use Test::File::Contents;
use File::Path qw(make_path remove_tree);
use lib 't/lib';
use MockOutput;

my $CLASS = 'App::Sqitch::Command::add_step';

ok my $sqitch = App::Sqitch->new, 'Load a sqitch sqitch object';
my $config = $sqitch->config;
isa_ok my $add_step = App::Sqitch::Command->load( {
        sqitch  => $sqitch,
        command => 'add-step',
        config  => $config,
    }
    ),
    $CLASS, 'add_step command';

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
    execute
    _find
    _load
    _add
);

is_deeply [ $CLASS->options ], [ qw(
        requires|r=s@
        conflicts|c=s@
        set|s=s%
        template-directory=s
        deploy-template=s
        revert-template=s
        test-template=s
        deploy!
        revert!
        test!
        )
    ],
    'Options should be set up';

sub contents_of ($) {
    my $file = shift;
    open my $fh, "<:encoding(UTF-8)", $file or die "cannot open $file: $!";
    local $/;
    return <$fh>;
}

##############################################################################
# Test configure().
is_deeply $CLASS->configure( $config, {} ),
    {
    requires  => [],
    conflicts => [],
    },
    'Should have default configuration with no config or opts';

is_deeply $CLASS->configure(
    $config,
    {
        requires  => [qw(foo bar)],
        conflicts => ['baz'],
    }
    ),
    {
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    },
    'Should have get requires and conflicts options';

is_deeply $CLASS->configure( $config, { template_directory => 't' } ),
    {
    requires           => [],
    conflicts          => [],
    template_directory => Path::Class::dir('t'),
    },
    'Should set up template directory option';

is_deeply $CLASS->configure(
    $config,
    {
        deploy          => 1,
        revert          => 1,
        test            => 0,
        deploy_template => 'templates/deploy.tmpl',
        revert_template => 'templates/revert.tmpl',
        test_template   => 'templates/test.tmpl',
    }
    ),
    {
    requires        => [],
    conflicts       => [],
    with_deploy     => 1,
    with_revert     => 1,
    with_test       => 0,
    deploy_template => Path::Class::file('templates/deploy.tmpl'),
    revert_template => Path::Class::file('templates/revert.tmpl'),
    test_template   => Path::Class::file('templates/test.tmpl'),
    },
    'Should have get template options';

# Test variable configuration.
CONFIG: {
    local $ENV{SQITCH_CONFIG} = File::Spec->catfile(qw(t add_step.conf));
    my $config = App::Sqitch::Config->new;
    is_deeply $CLASS->configure( $config, {} ),
        {
        requires  => [],
        conflicts => [],
        },
        'Variables should by default not be loaded from config';

    is_deeply $CLASS->configure( $config, { set => { yo => 'dawg' } } ),
        {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'bar',
            baz => [qw(hi there you)],
            yo  => 'dawg',
        },
        },
        '--set should be merged with config variables';

    is_deeply $CLASS->configure( $config, { set => { foo => 'ick' } } ),
        {
        requires  => [],
        conflicts => [],
        variables => {
            foo => 'ick',
            baz => [qw(hi there you)],
        },
        },
        '--set should be override config variables';
}

##############################################################################
# Test attributes.
is_deeply $add_step->requires,  [], 'Requires should be an arrayref';
is_deeply $add_step->conflicts, [], 'Conflicts should be an arrayref';
is_deeply $add_step->variables, {}, 'Varibles should be a hashref';
is $add_step->template_directory, undef, 'Default dir should be undef';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock( system_dir => Path::Class::dir('nonexistent') );
    for my $script (qw(deploy revert test)) {
        my $with = "with_$script";
        ok $add_step->$with, "$with should be true by default";
        my $tmpl = "$script\_template";
        throws_ok { $add_step->$tmpl } qr/FAIL/, "Should die on $tmpl";
        is_deeply +MockOutput->get_fail, [ ["Cannot find $script template"] ],
            "Should get $tmpl failure message";
    }
}

# Point to a valid template directory.
ok $add_step = $CLASS->new(
    sqitch             => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
    ),
    'Create add_step with template_directory';

for my $script (qw(deploy revert test)) {
    my $tmpl = "$script\_template";
    is $add_step->$tmpl,
        Path::Class::file( 'etc', 'templates', "$script.tmpl" ),
        "Should find $script in templates directory";
}

##############################################################################
# Test find().
is $add_step->_find('deploy'),
    Path::Class::file(qw(etc templates deploy.tmpl)),
    '_find should work with template_directory';

ok $add_step = $CLASS->new( sqitch => $sqitch ),
    'Create add_step with no template directory';

MOCKCONFIG: {
    my $config_mock = Test::MockModule->new('App::Sqitch::Config');
    $config_mock->mock( system_dir => Path::Class::dir('nonexistent') );
    $config_mock->mock( user_dir   => Path::Class::dir('etc') );
    is $add_step->_find('deploy'),
        Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with user_dir from Config';

    $config_mock->unmock('user_dir');
    throws_ok { $add_step->_find('test') } qr/FAIL/,
        "Should die trying to find template";
    is_deeply +MockOutput->get_fail, [ ["Cannot find test template"] ],
        "Should get unfound test template message";

    $config_mock->mock( system_dir => Path::Class::dir('etc') );
    is $add_step->_find('deploy'),
        Path::Class::file(qw(etc templates deploy.tmpl)),
        '_find should work with system_dir from Config';
}

##############################################################################
# Test _load().
my $tmpl = Path::Class::file(qw(etc templates deploy.tmpl));
is $ { $add_step->_load($tmpl) }, contents_of $tmpl,
    '_load() should load a reference to file contents';

##############################################################################
# Test _add().
make_path 'sql';
END { remove_tree 'sql' }
my $out = File::Spec->catfile( 'sql', 'sqitch_step_test.sql' );
file_not_exists_ok $out;
ok $add_step->_add( 'sqitch_step_test', $tmpl, Path::Class::dir('sql') ),
    'Write out a script';
file_exists_ok $out;
file_contents_is $out, <<EOF, 'The template should have been evaluated';
-- Deploy sqitch_step_test

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF

# Try with requires and conflicts.
ok $add_step = $CLASS->new(
    sqitch    => $sqitch,
    requires  => [qw(foo bar)],
    conflicts => ['baz'],
    ),
    'Create add_step cmd with requires and conflicts';

$out = File::Spec->catfile( 'sql', 'another_step_test.sql' );
ok $add_step->_add( 'another_step_test', $tmpl, Path::Class::dir('sql') ),
    'Write out a script with requires and conflicts';
file_contents_is $out,
    <<EOF, 'The template should have been evaluated with requires and conflicts';
-- Deploy another_step_test
-- :requires: foo
-- :requires: bar
-- :conflicts: baz

BEGIN;

-- XXX Add DDLs here.

COMMIT;
EOF

##############################################################################
# Test execute.
ok $add_step = $CLASS->new(
    sqitch             => $sqitch,
    template_directory => Path::Class::dir(qw(etc templates))
    ),
    'Create another add_step with template_directory';

unlink $out;
dir_not_exists_ok +File::Spec->catdir( 'sql', $_ ) for qw(deploy revert test);
ok $add_step->execute('widgets_table'), 'Add step "widgets_table"';
file_exists_ok +File::Spec->catfile( 'sql', $_, 'widgets_table.sql' )
    for qw(deploy revert test);
file_contents_like +File::Spec->catfile(qw(sql deploy widgets_table.sql)),
    qr/^-- Deploy widgets_table/, 'Deploy script should look right';
file_contents_like +File::Spec->catfile(qw(sql revert widgets_table.sql)),
    qr/^-- Revert widgets_table/, 'Revert script should look right';
file_contents_like +File::Spec->catfile(qw(sql test widgets_table.sql)),
    qr/^-- Test widgets_table/, 'Test script should look right';

# Make sure conflicts are avoided.
unlink +File::Spec->catfile(qw(sql deploy widgets_table.sql));
throws_ok { $add_step->execute('widgets_table') } qr/FAIL:/,
    'Should get exception when trying to create existing step';
is_deeply +MockOutput->get_fail, [ ['Step "widgets_table" already exists'] ],
    'Failure message should report that the step already exists';

