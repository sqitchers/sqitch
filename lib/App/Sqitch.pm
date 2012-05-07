package App::Sqitch;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Getopt::Long;
use Hash::Merge qw(merge);
use Path::Class;
use Config;
use App::Sqitch::Config;
use App::Sqitch::Command;
use Moose;
use List::Util qw(first);
use IPC::System::Simple qw(runx capturex $EXITVAL);
use Moose::Util::TypeConstraints;
use MooseX::Types::Path::Class;
use namespace::autoclean;

our $VERSION = '0.30';

has plan_file => (
    is       => 'ro',
    required => 1,
    default  => sub {
        file 'sqitch.plan';
    } );

has _engine => (
    is      => 'ro',
    lazy    => 1,
    isa     => maybe_type( enum [qw(pg mysql sqlite)] ),
    default => sub {
        shift->config->get( key => 'core.engine' );
    } );
has engine => (
    is      => 'ro',
    isa     => 'Maybe[App::Sqitch::Engine]',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $name = $self->_engine or return;
        require App::Sqitch::Engine;
        App::Sqitch::Engine->load( { sqitch => $self, engine => $name } );
    } );

# Attributes useful to engines; no defaults.
has client   => ( is => 'ro', isa => 'Str' );
has db_name  => ( is => 'ro', isa => 'Str' );
has username => ( is => 'ro', isa => 'Str' );
has host     => ( is => 'ro', isa => 'Str' );
has port     => ( is => 'ro', isa => 'Int' );

has sql_dir => (
    is       => 'ro',
    isa      => 'Maybe[Path::Class::Dir]',
    required => 1,
    lazy     => 1,
    default =>
        sub { dir shift->config->get( key => 'core.sql_dir' ) || 'sql' },
);

has deploy_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        if ( my $dir = $self->config->get( key => 'core.deploy_dir' ) ) {
            return dir $dir;
        }
        $self->sql_dir->subdir('deploy');
    },
);

has revert_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        if ( my $dir = $self->config->get( key => 'core.revert_dir' ) ) {
            return dir $dir;
        }
        $self->sql_dir->subdir('revert');
    },
);

has test_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        if ( my $dir = $self->config->get( key => 'core.test_dir' ) ) {
            return dir $dir;
        }
        $self->sql_dir->subdir('test');
    },
);

has extension => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        shift->config->get( key => 'core.extension' ) || 'sql';
    } );

has dry_run => ( is => 'ro', isa => 'Bool', required => 1, default => 0 );

has verbosity => (
    is       => 'ro',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->config->get( key => 'core.verbosity' ) // 1;
    } );

has config => (
    is      => 'ro',
    isa     => 'App::Sqitch::Config',
    lazy    => 1,
    default => sub {
        App::Sqitch::Config->new;
    } );

has editor => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        return
               $ENV{SQITCH_EDITOR}
            || $ENV{EDITOR}
            || shift->config->get( key => 'core.editor' )
            || ( $^O eq 'MSWin32' ? 'notepad.exe' : 'vi' );
    } );

sub go {
    my $class = shift;

    # 1. Split command and options.
    my ( $core_args, $cmd, $cmd_args ) = $class->_split_args(@ARGV);

    # 2. Parse core options.
    my $opts = $class->_parse_core_opts($core_args);

    # 3. Load config.
    my $config = App::Sqitch::Config->new;

    # 4. Instantiate Sqitch.
    $opts->{_engine} = delete $opts->{engine} if $opts->{engine};
    $opts->{config} = $config;
    my $sqitch = $class->new($opts);

    # 5. Instantiate the command object.
    my $command = App::Sqitch::Command->load( {
            sqitch  => $sqitch,
            command => $cmd,
            config  => $config,
            args    => $cmd_args,
    } );

    # 6. Execute command.
    return $command->execute( @{$cmd_args} ) ? 0 : 2;
}

sub _core_opts {
    return qw(
        plan-file=s
        engine=s
        client=s
        db-name|d=s
        username|user|u=s
        host=s
        port=i
        sql-dir=s
        deploy-dir=s
        revert-dir=s
        test-dir=s
        extension=s
        dry-run
        etc-path
        quiet
        verbose+
        help
        man
        version
    );
}

sub _split_args {
    my ( $self, @args ) = @_;

    my $cmd_at  = 0;
    my $add_one = sub { $cmd_at++ };
    my $add_two = sub { $cmd_at += 2 };

    Getopt::Long::Configure(qw(bundling));
    Getopt::Long::GetOptionsFromArray(
        [@args],

        # Halt processing on on first non-option, which will be the command.
        '<>' => sub { die '!FINISH' },

        # Count how many args we've processed until we die.
        map { $_ => m/=/ ? $add_two : $add_one } $self->_core_opts
    ) or $self->_pod2usage;

    # Splice the command and its options out of the arguments.
    my ( $cmd, @cmd_opts ) = splice @args, $cmd_at;
    return \@args, $cmd, \@cmd_opts;
}

sub _parse_core_opts {
    my ( $self, $args ) = @_;
    my %opts;
    Getopt::Long::Configure(qw(bundling pass_through));
    Getopt::Long::GetOptionsFromArray(
        $args,
        map {
            ( my $k = $_ ) =~ s/[|=+:!].*//;
            $k =~ s/-/_/g;
            $_ => \$opts{$k};
            } $self->_core_opts
    ) or $self->_pod2usage;

    # Handle documentation requests.
    $self->_pod2usage( '-exitval' => 0, '-verbose' => 2 )
        if delete $opts{man};
    $self->_pod2usage( '-exitval' => 0 ) if delete $opts{help};

    # Handle version request.
    if ( delete $opts{version} ) {
        require File::Basename;
        my $fn = File::Basename::basename($0);
        print $fn, ' (', __PACKAGE__, ') ', __PACKAGE__->VERSION, $/;
        exit;
    }

    # Handle --etc-path.
    if ( $opts{etc_path} ) {
        say App::Sqitch::Config->system_dir;
        exit;
    }

    # Normalize the options (remove undefs) and return.
    $opts{verbosity} = delete $opts{verbose};
    delete $opts{$_} for grep { !defined $opts{$_} } keys %opts;
    return \%opts;
}

sub _pod2usage {
    shift;
    require Pod::Usage;
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Synopsis|Usage|Options))',
        '-exitval'  => 2,
        @_
    );
}

sub run {
    my $self = shift;
    local $SIG{__DIE__} = sub {
        ( my $msg = shift ) =~ s/\s+at\s+.+/\n/ms;
        die $msg;
    };
    runx @_;
    return $self;
}

sub capture {
    my $self = shift;
    local $SIG{__DIE__} = sub {
        ( my $msg = shift ) =~ s/\s+at\s+.+/\n/ms;
        die $msg;
    };
    capturex @_;
}

sub probe {
    my ($ret) = shift->capture(@_);
    chomp $ret;
    return $ret;
}

sub _bn {
    require File::Basename;
    File::Basename::basename($0);
}

sub _prepend {
    my $prefix = shift;
    my $msg = join '', map { $_ // '' } @_;
    $msg =~ s/^/$prefix /gms;
    return $msg;
}

sub trace {
    my $self = shift;
    say _prepend 'trace:', @_ if $self->verbosity > 2;
}

sub debug {
    my $self = shift;
    say _prepend 'debug:', @_ if $self->verbosity > 1;
}

sub info {
    my $self = shift;
    say @_ if $self->verbosity;
}

sub comment {
    my $self = shift;
    say _prepend '#', @_ if $self->verbosity;
}

sub emit {
    shift;
    say @_;
}

sub warn {
    my $self = shift;
    say STDERR _prepend 'warning:', @_;
}

sub unfound {
    exit 1;
}

sub fail {
    my $self = shift;
    say STDERR _prepend 'fatal:', @_;
    exit 2;
}

sub help {
    my $self = shift;
    my $bn   = _bn;
    say STDERR _prepend( "$bn:", @_ ), " See $bn --help";
    exit 1;
}

sub bail {
    my ( $self, $code ) = ( shift, shift );
    if (@_) {
        if ($code) {
            say STDERR @_;
        }
        else {
            say STDOUT @_;
        }
    }
    exit $code;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch - VCS-powered SQL change management

=head1 Synopsis

  user App::Sqitch;
  exit App::Sqitch->go;

=head1 Description

This module provides the implementation for L<sqitch>. You probably want to
read L<its documentation|sqitch>, or L<the tutorial|sqitchtutorial>. Unless
you want to hack on Sqitch itself, or provide support for a new engine or
L<command|Sqitch::App::Command>. In which case, you will find this API
documentation useful.

=head1 Interface

=head2 Class Methods

=head3 C<go>

  App::Sqitch->go;

Called from C<sqitch>, this class method parses command-line options and
arguments in C<@ARGV>, parses the configuration file, constructs an
App::Sqitch object, constructs a command object, and runs it.

=head2 Constructor

=head3 C<new>

  my $sqitch = App::Sqitch->new(\%params);

Constructs and returns a new Sqitch object. The supported parameters include:

=over

=item C<plan_file>

=item C<engine>

=item C<client>

=item C<db_name>

=item C<username>

=item C<host>

=item C<port>

=item C<sql_dir>

=item C<deploy_dir>

=item C<revert_dir>

=item C<test_dir>

=item C<extension>

=item C<dry_run>

=item C<editor>

=item C<verbosity>

=back

=head2 Accessors

=head3 C<plan_file>

=head3 C<engine>

=head3 C<client>

=head3 C<db_name>

=head3 C<username>

=head3 C<host>

=head3 C<port>

=head3 C<sql_dir>

=head3 C<deploy_dir>

=head3 C<revert_dir>

=head3 C<test_dir>

=head3 C<extension>

=head3 C<dry_run>

=head3 C<editor>

=head3 C<config>

  my $config = $sqitch->config;

Returns the full configuration, combined from the project, user, and system
configuration files.

=head3 C<verbosity>

=head2 Instance Methods

=head3 C<run>

  $sqitch->run('echo hello');

Runs a system command and waits for it to finish. Throws an exception on
error.

=head3 C<capture>

  my @files = $sqitch->capture(qw(ls -lah));

Runs a system command and captures its output to C<STDOUT>. Returns the
output lines in list context and the concatenation of the lines in scalar
context. Throws an exception on error.

=head3 C<probe>

  my $git_version = $sqitch->capture(qw(git --version));

Like C<capture>, but returns just the C<chomp>ed first line of output.

=head3 C<trace>

  $sqitch->trace('About to fuzzle the wuzzle.');

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<trace: > prefixed to every line. If it's lower
than 3, nothing will be output.

=head3 C<debug>

  $sqitch->debug('Found snuggle in the crib.');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<debug: > prefixed to every line. If it's lower
than 2, nothing will be output.

=head3 C<info>

  $sqitch->info('Nothing to deploy (up-to-date)');

Send informational message to C<STDOUT> if the verbosity level is 1 or
higher, which, by default, it is. Should be used for normal messages the user
would normally want to see. If verbosity is lower than 1, nothing will be
output.

=head3 C<comment>

  $sqitch->comment('On database flipr_test');

Send comments to C<STDOUT> if the verbosity level is 1 or higher, which, by
default, it is. Comments have C<# > prefixed to every line. If verbosity is
lower than 1, nothing will be output.

=head3 C<emit>

  $sqitch->emit('core.editor=emacs');

Send a message to C<STDOUT>, without regard to the verbosity. Should be used
only if the user explicitly asks for output, such as for C<sqitch config
--get core.editor>.

=head3 C<warn>

  $sqitch->warn('Could not find nerble; using nobble instead.');

Send a warning messages to C<STDERR>. Warnings will have C<warning: >
prefixed to every line. Use if something unexpected happened but you can
recover from it.

=head3 C<unfound>

  $sqitch->unfound;

Exit the program with status code 1. Best for use for non-fatal errors, such
as when something requested was not found.

=head3 C<fail>

  $sqitch->fail('File or directory "foo" not found.');

Send a failure message to C<STDERR> and exit with status code 2. Failures
will have C<fatal: > prefixed to every line. Use if something unexpected
happened and you cannot recover from it.

=head3 C<help>

  $sqitch->help('"foo" is not a valid command.');

Sends messages to C<STDERR> and exists with an additional message to "See
sqitch --help". Help messages will have C<sqitch: > prefixed to every line.
Use if the user has misused the app.

=head3 C<bail>

  $sqitch->bail(3, 'The config file is invalid');

Exits with the specified error code, sending any specified messages to
C<STDOUT> if the exit code is 0, and to C<STDERR> if it is not 0.

=head1 To Do

=over

=item *

Add checks to L<sqitch-add-step> to halt if a C<--requires> or C<--conflicts>
step does not exist.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
