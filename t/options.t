#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More tests => 184;
#use Test::More 'no_plan';
use Test::MockModule;
use Test::Exception;
use Capture::Tiny 0.12 ':all';
use Locale::TextDomain qw(App-Sqitch);
use lib 't/lib';
use TestConfig;

my ($catch_chdir, $chdir_to, $chdir_fail);
BEGIN {
    $catch_chdir = 0;
    # Stub out chdir.
    *CORE::GLOBAL::chdir = sub {
        return CORE::chdir(@_) unless $catch_chdir;
        $chdir_to = shift;
        return !$chdir_fail;
    };
}

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch';
    use_ok $CLASS or die;
}

##############################################################################
# Test _find_cmd.
can_ok $CLASS, '_find_cmd';

CMD: {
    # Mock output methods.
    my $mocker = Test::MockModule->new($CLASS);
    my $pod;
    $mocker->mock(_pod2usage => sub { $pod = $_[1]; undef });
    my @vent;
    $mocker->mock(vent => sub { shift; push @vent => \@_ });

    # Try no args.
    my @args = ();
    is $CLASS->_find_cmd(\@args), undef, 'Should find no command for no args';
    is $pod, 'sqitchcommands', 'Should have passed "sqitchcommands" to _pod2usage';
    is_deeply \@vent, [], 'Should have vented nothing';
    ($pod, @vent) = ();

    # Try an invalid command.
    @args = qw(barf);
    is $CLASS->_find_cmd(\@args), undef, 'Should find no command for invalid command';
    is $pod, 'sqitchcommands', 'Should have passed "sqitchcommands" to _pod2usage';
    is_deeply \@vent, [
        [__x '"{command}" is not a valid command',  command => 'barf'],
    ], 'Should have vented an invalid command message';
    ($pod, @vent) = ();

    # Obvious options should be ignored.
    for my $opt (qw(
        --foo
        --client=psql
        -R
        -X=yup
    )) {
        @args = ($opt, 'crack');
        is $CLASS->_find_cmd(\@args), undef,
            "Should find no command with option $opt";
        is $pod, 'sqitchcommands', 'Should have passed "sqitchcommands" to _pod2usage';
        is_deeply \@vent, [
            [__x '"{command}" is not a valid command',  command => 'crack'],
        ], qq{Should not have reported $opt as invalid command};
        ($pod, @vent) = ();
    }

    # Legacy options should be ignored.
    for my $opt (qw(
        --engine
        --client --db-client
        --db-name -d
        --db-username -db-user -u
        --db-host -h
        --db-port -p
        --extension
    )) {
        @args = ($opt, 'deploy');
        is $CLASS->_find_cmd(\@args), undef,
            "Should find no command after legacy option $opt";
        is $pod, 'sqitchcommands', 'Should have passed "sqitchcommands" to _pod2usage';
        is_deeply \@vent, [], qq{Should have emitted no message with "$opt deploy"};
        ($pod, @vent) = ();

        # But it should find a valid command after that.
        @args = ($opt, qw(deploy tag -x));
        is $CLASS->_find_cmd(\@args), 'App::Sqitch::Command::tag',
            qq{"Should find valid command after "$opt deploy"};
        is $pod, undef, 'Should not have called _pod2usage';
        is_deeply \@vent, [], 'Should have vented nothing';
        is_deeply \@args, [$opt, qw(deploy -x)],
            qq{Should have removed valid command after "$opt deploy"};
    }

    # Lone -- should cancel processing.
    @args = ('--', 'tag');
    is $CLASS->_find_cmd(\@args), undef, 'Should find no command after --';
    is $pod, 'sqitchcommands', 'Should have passed "sqitchcommands" to _pod2usage';
    is_deeply \@vent, [], 'Should have vented nothing';
    ($pod, @vent) = ();

    # Valid command should be removed from args.
    for my $cmd (qw(bundle config help plan show tag)) {
        @args = (qw(--foo=bar -xy), $cmd, qw(--quack back -x y -z));
        my $class = "App::Sqitch::Command::$cmd";

        is $CLASS->_find_cmd(\@args), $class, qq{Should find class for "$cmd"};
        is $pod, undef, 'Should not have called _pod2usage';
        is_deeply \@vent, [], 'Should have vented nothing';
        is_deeply \@args, [qw(--foo=bar -xy --quack back -x y -z)],
            qq{Should have removed "$cmd" from args};
        ($pod, @vent) = ();

        @args = (qw(--foo=bar), $cmd, qw(verify -x));
        is $CLASS->_find_cmd(\@args), $class, qq{Should find class for "$cmd" again};
        is $pod, undef, 'Should not have called _pod2usage';
        is_deeply \@vent, [], 'Should have vented nothing';
        is_deeply \@args, [qw(--foo=bar verify -x)],
            qq{Should have left subsequent valid command after "$cmd" in args};
        ($pod, @vent) = ();
    }
}

##############################################################################
# Test _parse_core_opts
can_ok $CLASS, '_parse_core_opts';

is_deeply $CLASS->_parse_core_opts([]), {},
    'Should have default config for no options';

# Make sure we can get help.
HELP: {
    my $mock = Test::MockModule->new($CLASS);
    my @args;
    $mock->mock(_pod2usage => sub { @args = @_} );
    ok $CLASS->_parse_core_opts(['--help']), 'Ask for help';
    is_deeply \@args, [ $CLASS, 'sqitchcommands', '-exitval', 0, '-verbose', 2 ],
        'Should have been helped';
    ok $CLASS->_parse_core_opts(['--man']), 'Ask for man';
    is_deeply \@args, [ $CLASS, 'sqitch', '-exitval', 0, '-verbose', 2 ],
        'Should have been manned';
}

# Silence warnings.
my $mock = Test::MockModule->new($CLASS);
$mock->mock(warn => undef);

##############################################################################
# Try lots of options.
my $opts = $CLASS->_parse_core_opts([
    '--plan-file'  => 'plan.txt',
    '--engine'     => 'pg',
    '--registry'   => 'reg',
    '--client'     => 'psql',
    '--db-name'    => 'try',
    '--db-user'    => 'bob',
    '--db-host'    => 'local',
    '--db-port'    => 2020,
    '--top-dir'    => 'ddl',
    '--extension'  => 'ext',
    '--verbose', '--verbose',
    '--no-pager',
]);

is_deeply $opts, {
    plan_file   => 'plan.txt',
    engine      => 'pg',
    registry    => 'reg',
    client      => 'psql',
    db_name     => 'try',
    db_username => 'bob',
    db_host     => 'local',
    db_port     => 2020,
    top_dir     => 'ddl',
    extension   => 'ext',
    verbosity   => 2,
    no_pager    => 1,
}, 'Should parse lots of options';

isa_ok $opts->{plan_file}, 'Path::Class::File', 'plan_file';
isa_ok $opts->{top_dir}, 'Path::Class::Dir', 'top_dir';

# Make sure --quiet trumps --verbose.
is_deeply $CLASS->_parse_core_opts([
    '--verbose', '--verbose', '--quiet'
]), { verbosity => 0 }, '--quiet should trump verbosity.';

##############################################################################
# Try short options.
is_deeply $CLASS->_parse_core_opts([
  '-d' => 'mydb',
  '-u' => 'fred',
  '-h' => 'db1',
  '-p' => 5431,
  '-f' => 'foo.plan',
  '-vvv',
]), {
    db_name     => 'mydb',
    db_username => 'fred',
    db_host     => 'db1',
    db_port     => 5431,
    verbosity   => 3,
    plan_file   => 'foo.plan',
}, 'Short options should work';

USAGE: {
    my $mock = Test::MockModule->new('Pod::Usage');
    my %args;
    $mock->mock(pod2usage => sub { %args = @_} );
    ok $CLASS->_pod2usage('sqitch-add', foo => 'bar'), 'Run _pod2usage';
    is_deeply \%args, {
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-verbose'  => 2,
        '-input'    => Pod::Find::pod_where({'-inc' => 1 }, 'sqitch-add'),
        '-exitval'  => 2,
        'foo'       => 'bar',
    }, 'Proper args should have been passed to Pod::Usage';
}

# Test --directory.
$catch_chdir = 1;
ok $opts = $CLASS->_parse_core_opts(['--directory', 'foo/bar']),
    'Parse --directory';
is $chdir_to, 'foo/bar', 'Should have changed to foo/bar';
is_deeply $opts, {}, 'Should have preserved no opts';

ok $opts = $CLASS->_parse_core_opts(['-C', 'hi crampus']), 'Parse -C';
is $chdir_to, 'hi crampus', 'Should have changed to hi cramus';
is_deeply $opts, {}, 'Should have preserved no opts';

# Make sure it fails properly.
CHDIE: {
    local $! = 9;
    $chdir_fail = 1;
    throws_ok { $CLASS->_parse_core_opts(['-C', 'nonesuch']) }
        'App::Sqitch::X', 'Should get error when chdir fails';
    is $@->ident, 'fs', 'Error ident should be "fs"';
    is $@->message, __x(
        'Cannot change to directory {directory}: {error}',
        directory => 'nonesuch',
        error     => 'Bad file descriptor',
    ), 'Error message should be correct';
}
