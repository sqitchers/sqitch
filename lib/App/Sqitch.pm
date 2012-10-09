package App::Sqitch;

# ABSTRACT: Sane database change management

use 5.010;
use strict;
use warnings;
use utf8;
use Getopt::Long;
use Hash::Merge qw(merge);
use Path::Class;
use Config;
use Locale::TextDomain 1.20 qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Moose 2.0300;
use Encode qw(encode_utf8);
use Try::Tiny;
use List::Util qw(first);
use IPC::System::Simple 1.17 qw(runx capturex $EXITVAL);
use Moose::Util::TypeConstraints 2.0300;
use MooseX::Types::Path::Class 0.05;
use namespace::autoclean 0.11;

our $VERSION = '0.937';

BEGIN {
    # Need to create types before loading other Sqitch classes.
    subtype 'UserName', as 'Str', where {
        hurl user => __ 'User name may not contain "<" or start with "["'
            if /^[[]/ || /</;
        1;
    };

    subtype 'UserEmail', as 'Str', where {
        hurl user => __ 'User email may not contain ">"' if />/;
        1;
    };

    subtype 'CoreEngine', as 'Str', where {
        hurl core => __x('Unknown engine: {engine}', engine => $_)
            unless $_ ~~ [qw(pg sqlite)];
        1;
    };
}

# Okay to loas Sqitch classes now that typess are created.
use App::Sqitch::Config;
use App::Sqitch::Command;
use App::Sqitch::Plan;

has plan_file => (
    is       => 'ro',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->top_dir->file('sqitch.plan')->cleanup;
    }
);

has plan => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan',
    required => 1,
    lazy     => 1,
    default  => sub {
        App::Sqitch::Plan->new( sqitch => shift );
    },
);

has _engine => (
    is      => 'ro',
    lazy    => 1,
    isa     => 'CoreEngine',
    default => sub {
        shift->config->get( key => 'core.engine' ) || hurl core => __(
            'No engine specified; use --engine or set core.engine'
        );
    }
);

has engine => (
    is      => 'ro',
    isa     => 'App::Sqitch::Engine',
    lazy    => 1,
    default => sub {
        my $self = shift;
        require App::Sqitch::Engine;
        App::Sqitch::Engine->load({
            sqitch => $self,
            engine => $self->_engine,
        });
    }
);

# Attributes useful to engines; no defaults.
has db_client   => ( is => 'ro', isa => 'Str' );
has db_name     => ( is => 'ro', isa => 'Str' );
has db_username => ( is => 'ro', isa => 'Str' );
has db_host     => ( is => 'ro', isa => 'Str' );
has db_port     => ( is => 'ro', isa => 'Int' );

has top_dir => (
    is       => 'ro',
    isa      => 'Maybe[Path::Class::Dir]',
    required => 1,
    lazy     => 1,
    default => sub { dir shift->config->get( key => 'core.top_dir' ) || () },
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
        $self->top_dir->subdir('deploy')->cleanup;
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
        $self->top_dir->subdir('revert')->cleanup;
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
        $self->top_dir->subdir('test')->cleanup;
    },
);

has extension => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        shift->config->get( key => 'core.extension' ) || 'sql';
    }
);

has verbosity => (
    is       => 'ro',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->config->get( key => 'core.verbosity' ) // 1;
    }
);

has sysuser => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    default  => sub {
        # Adapted from User.pm.
        return getlogin
            || scalar getpwuid( $< )
            || $ENV{ LOGNAME }
            || $ENV{ USER }
            || $ENV{ USERNAME }
            || try { require Win32; Win32::LoginName() };
    },
);

has user_name => (
    is      => 'ro',
    lazy    => 1,
    isa     => 'UserName',
    default => sub {
        my $self = shift;
        $self->config->get( key => 'user.name' ) || do {
            my $sysname = $self->sysuser || hurl user => __(
                    'Cannot find your name; run sqitch config --user user.name "YOUR NAME"'
            );
            if ($^O eq 'MSWin32') {
                try { require Win32API::Net } || return $sysname;
                Win32API::Net::UserGetInfo( "", $sysname, 10, my $info = {} );
                return $info->{fullName} || $sysname;
            }
            require User::pwent;
            (User::pwent::getpwnam($sysname)->gecos)[0] || $sysname;
        };
    }
);

has user_email => (
    is      => 'ro',
    lazy    => 1,
    isa     => 'UserEmail',
    default => sub {
        my $self = shift;
        $self->config->get( key => 'user.email' ) || do {
            my $sysname = $self->sysuser || hurl user => __(
                'Cannot infer your email address; run sqitch config --user user.email you@host.com'
            );
            require Sys::Hostname;
            "$sysname@" . Sys::Hostname::hostname();
        };
    }
);

has config => (
    is      => 'ro',
    isa     => 'App::Sqitch::Config',
    lazy    => 1,
    default => sub {
        App::Sqitch::Config->new;
    }
);

has editor => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        return
             $ENV{SQITCH_EDITOR}
          || $ENV{EDITOR}
          || shift->config->get( key => 'core.editor' )
          || ( $^O eq 'MSWin32' ? 'notepad.exe' : 'vi' );
    }
);

has pager => (
    is       => 'ro',
    required => 1,
    lazy     => 1,
    isa      => type('IO::Pager' => where {
        # IO::Pager annoyingly just returns the file handle if there is no TTY.
        eval { $_->isa('IO::Pager') } || ref $_ eq 'GLOB'
    }),
    default  => sub {
        require IO::Pager;
        # https://rt.cpan.org/Ticket/Display.html?id=78270
        eval q{
            sub IO::Pager::say {
                my $self = shift;
                CORE::say {$self->{real_fh}} @_ or die "Could not print to PAGER: $!\n";
            }
        } unless IO::Pager->can('say');

        IO::Pager->new(\*STDOUT);
    },
);

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

    return try {
        # 5. Instantiate the command object.
        my $command = App::Sqitch::Command->load({
            sqitch  => $sqitch,
            command => $cmd,
            config  => $config,
            args    => $cmd_args,
        });

        # 6. Execute command.
        $command->execute( @{$cmd_args} ) ? 0 : 2;
    } catch {
        # Just bail for unknown exceptions.
        $sqitch->vent($_) && return 2 unless eval { $_->isa('App::Sqitch::X') };

        # It's one of ours. Vent.
        $sqitch->vent($_->message);

        # Emit the stack trace. DEV errors should be vented; otherwise trace.
        my $meth = $_->ident eq 'DEV' ? 'vent' : 'trace';
        $sqitch->$meth($_->stack_trace->as_string);

        # Bail.
        return $_->exitval;
    };
}

sub _core_opts {
    return qw(
        plan-file=s
        engine=s
        db-client=s
        db-name|d=s
        db-username|db-user|u=s
        db-host=s
        db-port=i
        top-dir|dir=s
        deploy-dir=s
        revert-dir=s
        test-dir=s
        extension=s
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
    if ($opts{help} || $opts{man}) {
        $self->_pod2usage(
            $opts{help} ? 'sqitchcommands' : 'sqitch',
            '-exitval' => 0,
            '-verbose' => 2,
        );
    }

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

    # Convert files and dirs to objects.
    for my $dir (qw(top_dir deploy_dir revert_dir test_dir)) {
        $opts{$dir} = dir $opts{$dir} if defined $opts{$dir};
    }
    $opts{plan_file} = file $opts{plan_file} if defined $opts{plan_file};

    # Normalize the options (remove undefs) and return.
    $opts{verbosity} = delete $opts{verbose};
    $opts{verbosity} = 0 if delete $opts{quiet};
    delete $opts{$_} for grep { !defined $opts{$_} } keys %opts;
    return \%opts;
}

sub _pod2usage {
    my ( $self, $doc ) = ( shift, shift );
    require App::Sqitch::Command::help;
    # Help does not need the Sqitch command; since it's required, fake it.
    my $help = App::Sqitch::Command::help->new( sqitch => bless {}, $self );
    $help->find_and_show( $doc || 'sqitch', '-exitval' => 2, @_ );
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

sub spool {
    my ($self, $fh) = (shift, shift);
    local $SIG{__WARN__} = sub { }; # Silence warning.
    my $pipe;
    if ($^O eq 'MSWin32') {
        require Win32::ShellQuote;
        open $pipe, '|' . Win32::ShellQuote::quote_native(@_) or hurl io => __x(
            'Cannot exec {command}: {error}',
            command => $_[0],
            error   => $!,
        );
    } else {
        open $pipe, '|-', @_ or hurl io => __x(
            'Cannot exec {command}: {error}',
            command => $_[0],
            error   => $!,
        );
    }

    local $SIG{PIPE} = sub { die 'spooler pipe broke' };
    print $pipe $_ while <$fh>;
    close $pipe or hurl io => $! ? __x(
        'Error closing pipe to {command}: {error}',
         command => $_[0],
         error   => $!,
    ) : __x(
        '{command} unexpectedly returned exit value {exitval}',
        command => $_[0],
        exitval => ($? >> 8),
    );
    return $self;
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

sub page {
    my $pager = shift->pager;
    # If the pager is a glob, we don't have to encode, because -CAS does it.
    return $pager->say(@_) if ref $pager eq 'GLOB';
    # If it is an object, we have to encode it. Ugh.
    $pager->say(encode_utf8 join '', map { $_ // '' } @_);
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
    say _prepend '#', @_;
}

sub emit {
    shift;
    say @_;
}

sub vent {
    shift;
    say STDERR @_;
}

sub warn {
    my $self = shift;
    say STDERR _prepend 'warning:', @_;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch - Sane database change management

=head1 Synopsis

  use App::Sqitch;
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

=item C<db_client>

=item C<db_name>

=item C<db_username>

=item C<user_name>

=item C<user_email>

=item C<db_host>

=item C<db_port>

=item C<top_dir>

=item C<deploy_dir>

=item C<revert_dir>

=item C<test_dir>

=item C<extension>

=item C<editor>

=item C<verbosity>

=back

=head2 Accessors

=head3 C<plan_file>

=head3 C<engine>

=head3 C<db_client>

=head3 C<db_name>

=head3 C<db_username>

=head3 C<user_name>

=head3 C<user_email>

=head3 C<db_host>

=head3 C<db_port>

=head3 C<top_dir>

=head3 C<deploy_dir>

=head3 C<revert_dir>

=head3 C<test_dir>

=head3 C<extension>

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

Runs a system command and captures its output to C<STDOUT>. Returns the output
lines in list context and the concatenation of the lines in scalar context.
Throws an exception on error.

=head3 C<probe>

  my $git_version = $sqitch->capture(qw(git --version));

Like C<capture>, but returns just the C<chomp>ed first line of output.

=head3 C<spool>

  $sqitch->spool($sql_file_handle, 'sqlite3', 'my.db');

Like run, but spools the contents of a file handle to the standard input the
system command. Returns true on success and throws an exception on failure.

=head3 C<trace>

  $sqitch->trace('About to fuzzle the wuzzle.');

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<trace: > prefixed to every line. If it's lower than
3, nothing will be output.

=head3 C<debug>

  $sqitch->debug('Found snuggle in the crib.');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<debug: > prefixed to every line. If it's lower than
2, nothing will be output.

=head3 C<info>

  $sqitch->info('Nothing to deploy (up-to-date)');

Send informational message to C<STDOUT> if the verbosity level is 1 or higher,
which, by default, it is. Should be used for normal messages the user would
normally want to see. If verbosity is lower than 1, nothing will be output.

=head3 C<comment>

  $sqitch->comment('On database flipr_test');

Send comments to C<STDOUT> if the verbosity level is 1 or higher, which, by
default, it is. Comments have C<# > prefixed to every line. If verbosity is
lower than 1, nothing will be output.

=head3 C<emit>

  $sqitch->emit('core.editor=emacs');

Send a message to C<STDOUT>, without regard to the verbosity. Should be used
only if the user explicitly asks for output, such as for
C<sqitch config --get core.editor>.

=head3 C<vent>

  $sqitch->vent('That was a misage.');

Send a message to C<STDERR>, without regard to the verbosity. Should be used
only for error messages to be printed before exiting with an error, such as
when reverting failed changes.

=head3 C<page>

  $sqitch->page('Search results:');

Like C<emit()>, but sends the output to a pager handle rather than C<STDOUT>.
Unless there is no TTY (such as when output is being piped elsewhere), in
which case it I<is> sent to C<STDOUT>. Meant to be used to send a lot of data
to the user at once, such as when display the results of searching the event
log:

  $iter = $sqitch->engine->search_events;
  while ( my $change = $iter->() ) {
      $sqitch->page(join ' - ', @{ $change }{ qw(change_id event change) });
  }

=head3 C<warn>

  $sqitch->warn('Could not find nerble; using nobble instead.');

Send a warning messages to C<STDERR>. Warnings will have C<warning: > prefixed
to every line. Use if something unexpected happened but you can recover from
it.

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

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
