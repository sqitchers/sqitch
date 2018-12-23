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
use Locale::Messages qw(bind_textdomain_filter);
use App::Sqitch::X qw(hurl);
use Moo 1.002000;
use Type::Utils qw(where declare);
use App::Sqitch::Types qw(Str Int UserName UserEmail Maybe File Dir Config HashRef);
use Encode ();
use Try::Tiny;
use List::Util qw(first);
use IPC::System::Simple 1.17 qw(runx capturex $EXITVAL);
use namespace::autoclean 0.16;
use constant ISWIN => $^O eq 'MSWin32';

our $VERSION = '0.9999';

BEGIN {
    # Force Locale::TextDomain to encode in UTF-8 and to decode all messages.
    $ENV{OUTPUT_CHARSET} = 'UTF-8';
    bind_textdomain_filter 'App-Sqitch' => \&Encode::decode_utf8;
}

# Okay to load Sqitch classes now that types are created.
use App::Sqitch::Config;
use App::Sqitch::Command;
use App::Sqitch::Plan;

has options => (
    is      => 'ro',
    isa     => HashRef,
    default => sub { {} },
);

has verbosity => (
    is       => 'ro',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        $self->options->{verbosity} // $self->config->get( key => 'core.verbosity' ) // 1;
    }
);

has sysuser => (
    is       => 'ro',
    isa      => Maybe[Str],
    lazy     => 1,
    default  => sub {
        $ENV{ SQITCH_ORIG_SYSUSER } || do {
            # Adapted from User.pm.
            require Encode::Locale;
            return Encode::decode( locale => getlogin )
                || Encode::decode( locale => scalar getpwuid( $< ) )
                || $ENV{ LOGNAME }
                || $ENV{ USER }
                || $ENV{ USERNAME }
                || try {
                    require Win32;
                    Encode::decode( locale => Win32::LoginName() )
                };
        };
    },
);

has user_name => (
    is      => 'ro',
    lazy    => 1,
    isa     => UserName,
    default => sub {
        my $self = shift;
        $ENV{ SQITCH_FULLNAME }
            || $self->config->get( key => 'user.name' )
            || $ENV{ SQITCH_ORIG_FULLNAME }
        || do {
            my $sysname = $self->sysuser || hurl user => __(
                    'Cannot find your name; run sqitch config --user user.name "YOUR NAME"'
            );
            if (ISWIN) {
                try { require Win32API::Net } || return $sysname;
                Win32API::Net::UserGetInfo( "", $sysname, 10, my $info = {} );
                return $sysname unless $info->{fullName};
                require Encode::Locale;
                return Encode::decode( locale => $info->{fullName} );
            }
            require User::pwent;
            my $name = (User::pwent::getpwnam($sysname)->gecos)[0]
                || return $sysname;
            require Encode::Locale;
            return Encode::decode( locale => $name );
        };
    }
);

has user_email => (
    is      => 'ro',
    lazy    => 1,
    isa     => UserEmail,
    default => sub {
        my $self = shift;
         $ENV{ SQITCH_EMAIL }
            || $self->config->get( key => 'user.email' )
            || $ENV{ SQITCH_ORIG_EMAIL }
        || do {
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
    isa     => Config,
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
          || shift->config->get( key => 'core.editor' )
          || $ENV{VISUAL}
          || $ENV{EDITOR}
          || ( ISWIN ? 'notepad.exe' : 'vi' );
    }
);

has pager_program => (
    is      => "ro",
    lazy    => 1,
    default => sub {
        my $self = shift;
        return
            $ENV{SQITCH_PAGER}
         || $self->config->get(key => "core.pager")
         || $ENV{PAGER};
    },
);

has pager => (
    is       => 'ro',
    lazy     => 1,
    isa      => declare('Pager', where {
        # IO::Pager annoyingly just returns the file handle if there is no TTY.
        eval { $_->isa('IO::Pager') || $_->isa('IO::Handle') } || ref $_ eq 'GLOB'
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

        my $fh = IO::Pager->new(\*STDOUT);
        if (eval { $fh->isa('IO::Pager') }) {
            $fh->binmode(':utf8_strict');
        } else {
            binmode $fh, ':utf8_strict';
        }
        $fh;
    },
);

sub go {
    my $class = shift;

    # 1. Split command and options.
    my ( $core_args, $cmd, $cmd_args ) = $class->_split_args(@ARGV);

    # 2. Parse core options.
    my $opts = $class->_parse_core_opts($core_args);

    # 3. If there is no command, emit help that lists commands.
    $class->_pod2usage('sqitchcommands') unless $cmd;

    # 4. Load config.
    my $config = App::Sqitch::Config->new;

    # 5. Instantiate Sqitch.
    my $sqitch = $class->new({ options => $opts, config  => $config });

    return try {
        # 6. Instantiate the command object.
        my $command = App::Sqitch::Command->load({
            sqitch  => $sqitch,
            command => $cmd,
            config  => $config,
            args    => $cmd_args,
        });

        # IO::Pager respects the PAGER environment variable.
        local $ENV{PAGER} = $sqitch->pager_program;

        # 7. Execute command.
        $command->execute( @{$cmd_args} ) ? 0 : 2;
    } catch {
        # Just bail for unknown exceptions.
        $sqitch->vent($_) && return 2 unless eval { $_->isa('App::Sqitch::X') };

        # It's one of ours.
        if ($_->exitval == 1) {
            # Non-fatal exception; just send the message to info.
            $sqitch->info($_->message);
        } else {
            # Fatal exception; vent.
            $sqitch->vent($_->message);

            # Emit the stack trace. DEV errors should be vented; otherwise trace.
            my $meth = $_->ident eq 'DEV' ? 'vent' : 'trace';
            $sqitch->$meth($_->stack_trace->as_string);
        }

        # Bail.
        return $_->exitval;
    };
}

sub _core_opts {
    return qw(
        plan-file|f=s
        engine=s
        registry=s
        directory|C=s
        client|db-client=s
        db-name|d=s
        db-username|db-user|u=s
        db-host|h=s
        db-port|p=i
        top-dir|dir=s
        deploy-dir=s
        revert-dir=s
        verify-dir|test-dir=s
        extension=s
        etc-path
        quiet
        verbose|v+
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

    Getopt::Long::GetOptionsFromArray(
        # remove bundled options, or we lose track of our position.
        [map { /^-([^-]{2,})/ ? '-' . substr $1, -1 : $_ } @args],
        # Halt processing on on first non-option, which will be the command.
        '<>' => sub { die '!FINISH' },
        # Count how many args we've processed until we die.
        map { $_ => m/=/ ? $add_two : $add_one } $self->_core_opts
    ) or $self->_pod2usage('sqitchusage', '-verbose' => 99 );

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
    ) or $self->_pod2usage('sqitchusage', '-verbose' => 99 );

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
        print $fn, ' (', __PACKAGE__, ') ', __PACKAGE__->VERSION, "\n";
        exit;
    }

    # Handle --etc-path.
    if ( $opts{etc_path} ) {
        say App::Sqitch::Config->class->system_dir;
        exit;
    }

    # Handle --directory
    if ( my $dir = delete $opts{directory} ) {
        chdir $dir or hurl fs => __x(
            'Cannot change to directory {directory}: {error}',
            directory => $dir,
            error   => $!,
        );
    }

    # Convert files and dirs to objects.
    for my $dir (qw(
        top_dir
        deploy_dir
        revert_dir
        verify_dir
    )) {
        next unless defined $opts{$dir};
        if ($dir ne 'top_dir') {
            # XXX deprecated.
            (my $opt = $dir) =~ s/_/-/;
            $self->warn(__x(
                qq{  The "{opt}" option is deprecated;\n  Instead use "--dir {dir}={val}" if available.},
                opt => $opt,
                dir => $dir,
                val => $opts{$dir},
            ));
        }
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
    runx ( shift, $self->quote_shell(@_) )
        if ISWIN && IPC::System::Simple->VERSION <= 1.25;
    runx @_;
    return $self;
}

sub shell {
    my ($self, $cmd) = @_;
    local $SIG{__DIE__} = sub {
        ( my $msg = shift ) =~ s/\s+at\s+.+/\n/ms;
        die $msg;
    };
    IPC::System::Simple::run $cmd;
    return $self;
}

sub quote_shell {
    my $self = shift;
    if (ISWIN) {
        require Win32::ShellQuote;
        return Win32::ShellQuote::quote_native(@_);
    }
    require String::ShellQuote;
    return String::ShellQuote::shell_quote(@_);
}

sub capture {
    my $self = shift;
    local $SIG{__DIE__} = sub {
        ( my $msg = shift ) =~ s/\s+at\s+.+/\n/ms;
        die $msg;
    };
    return capturex ( shift, $self->quote_shell(@_) )
        if ISWIN && IPC::System::Simple->VERSION <= 1.25;
    capturex @_;
}

sub _is_interactive {
  return -t STDIN && (-t STDOUT || !(-f STDOUT || -c STDOUT)) ;   # Pipe?
}

sub _is_unattended {
    my $self = shift;
    return !$self->_is_interactive && eof STDIN;
}

sub _readline {
    my $self = shift;
    return undef if $self->_is_unattended;
    my $answer = <STDIN>;
    chomp $answer if defined $answer;
    return $answer;
}

sub prompt {
    my $self = shift;
    my $msg  = shift or hurl 'prompt() called without a prompt message';

    # use a list to distinguish a default of undef() from no default
    my @def;
    @def = (shift) if @_;
    # use dispdef for output
    my @dispdef = scalar(@def)
        ? ('[', (defined($def[0]) ? $def[0] : ''), '] ')
        : ('', '');

    # Don't use emit because it adds a newline.
    local $|=1;
    print $msg, ' ', @dispdef;

    if ($self->_is_unattended) {
        hurl io => __(
            'Sqitch seems to be unattended and there is no default value for this question'
        ) unless @def;
        print "$dispdef[1]\n";
    }

    my $ans = $self->_readline;

    if ( !defined $ans or !length $ans ) {
        # Ctrl-D or user hit return;
        $ans = @def ? $def[0] : '';
    }

    return $ans;
}

sub ask_y_n {
    my $self = shift;
    my ($msg, $def)  = @_;

    hurl 'ask_y_n() called without a prompt message' unless $msg;
    hurl 'Invalid default value: ask_y_n() default must be "y" or "n"'
        if $def && $def !~ /^[yn]/i;

    my $answer;
    my $i = 3;
    while ($i--) {
        $answer = $self->prompt(@_);
        return 1 if $answer =~ /^y/i;
        return 0 if $answer =~ /^n/i;
        $self->emit(__ 'Please answer "y" or "n".');
    }

    hurl io => __ 'No valid answer after 3 attempts; aborting';
}

sub spool {
    my ($self, $fh) = (shift, shift);
    local $SIG{__WARN__} = sub { }; # Silence warning.
    my $pipe;
    if (ISWIN) {
        no warnings;
        open $pipe, '|' . $self->quote_shell(@_) or hurl io => __x(
            'Cannot exec {command}: {error}',
            command => $_[0],
            error   => $!,
        );
    } else {
        no warnings;
        open $pipe, '|-', @_ or hurl io => __x(
            'Cannot exec {command}: {error}',
            command => $_[0],
            error   => $!,
        );
    }

    local $SIG{PIPE} = sub { die 'spooler pipe broke' };
    if (ref $fh eq 'ARRAY') {
        for my $h (@{ $fh }) {
            print $pipe $_ while <$h>;
        }
    } else {
        print $pipe $_ while <$fh>;
    }

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
    chomp $ret if $ret;
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
    return $pager->say(@_);
}

sub page_literal {
    my $pager = shift->pager;
    return $pager->print(@_);
}

sub trace {
    my $self = shift;
    $self->emit( _prepend 'trace:', @_ ) if $self->verbosity > 2;
}

sub trace_literal {
    my $self = shift;
    $self->emit_literal( _prepend 'trace:', @_ ) if $self->verbosity > 2;
}

sub debug {
    my $self = shift;
    $self->emit( _prepend 'debug:', @_ ) if $self->verbosity > 1;
}

sub debug_literal {
    my $self = shift;
    $self->emit_literal( _prepend 'debug:', @_ ) if $self->verbosity > 1;
}

sub info {
    my $self = shift;
    $self->emit(@_) if $self->verbosity;
}

sub info_literal {
    my $self = shift;
    $self->emit_literal(@_) if $self->verbosity;
}

sub comment {
    my $self = shift;
    $self->emit( _prepend '#', @_ );
}

sub comment_literal {
    my $self = shift;
    $self->emit_literal( _prepend '#', @_ );
}

sub emit {
    shift;
    local $|=1;
    say @_;
}

sub emit_literal {
    shift;
    local $|=1;
    print @_;
}

sub vent {
    shift;
    my $fh = select;
    select STDERR;
    local $|=1;
    say STDERR @_;
    select $fh;
}

sub vent_literal {
    shift;
    my $fh = select;
    select STDERR;
    local $|=1;
    print STDERR @_;
    select $fh;
}

sub warn {
    my $self = shift;
    $self->vent(_prepend 'warning:', @_);
}

sub warn_literal {
    my $self = shift;
    $self->vent_literal(_prepend 'warning:', @_);
}

1;

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

=item C<options>

=item C<user_name>

=item C<user_email>

=item C<editor>

=item C<verbosity>

=back

=head2 Accessors

=head3 C<user_name>

=head3 C<user_email>

=head3 C<editor>

=head3 C<options>

  my $options = $sqitch->options;

Returns a hashref of the core command-line options.

=head3 C<config>

  my $config = $sqitch->config;

Returns the full configuration, combined from the project, user, and system
configuration files.

=head3 C<verbosity>

=head2 Instance Methods

=head3 C<run>

  $sqitch->run('echo', '-n', 'hello');

Runs a system command and waits for it to finish. Throws an exception on
error. Does not use the shell, so arguments must be passed as a list. Use
C<shell> to run a command and its arguments as a single string.

=head3 C<engine>

  my $engine = $sqitch->engine(@params);

Creates and returns an engine of the appropriate subclass. Pass in additional
parameters to be passed through to the engine constructor.

=head2 C<config_for_target>

  my $config = $sqitch->config_for_target($target);

Returns a hash reference representing the configuration for the specified
target name or URI. The supported keys in the hash reference are:

=over

=item C<target>

The name of the target, as passed.

=item C<uri>

A L<database URI|URI::db> object, to be used to connect to the target
database.


=item C<registry>

The name of the Sqitch registry in the target database.

=back

If the C<$target> argument looks like a database URI, it will simply returned
in the hash reference. If the C<$target> argument corresponds to a target
configuration key, the target configuration will be returned, with the C<uri>
value a upgraded to a L<URI> object. Otherwise returns C<undef>.

=head2 C<engine_key>

  my $key = $sqitch->engine_key;
  my $key = $sqitch->engine_key($uri);

Returns the key name of the engine. If C<--engine> was specified, its value
will be used. If the C<$uri> argument is passed and is a L<URI::db> object,
the key will be derived from its database driver. Otherwise, the value
specified for the C<core.engine> variable will be used.

=head2 C<config_for_target_strict>

  my $config = $sqitch->config_for_target_strict($target);

Like C<config_for_target>, but throws an exception if C<$target> is not a URL,
does not correspond to a target configuration section, or does not include a
C<uri> key. Otherwise returns the target configuration.

=head3 C<engine_for_target>

  my $engine = $sqitch->engine_for($target);

Like C<config_for_target_strict>, but returns an L<App::Sqitch::Engine>
object. If C<$target> is not defined or is empty, an engine will be returned
for the default target.

=head3 C<shell>

  $sqitch->shell('echo -n hello');

Shells out a system command and waits for it to finish. Throws an exception on
error. Always uses the shell, so a single string must be passed encapsulating
the entire command and its arguments. Use C<quote_shell> to assemble strings
into a single shell command. Use C<run> to execute a list without a shell.

=head3 C<quote_shell>

  my $cmd = $sqitch->quote_shell('echo', '-n', 'hello');

Assemble a list into a single string quoted for execution by C<shell>. Useful
for combining a specified command, such as C<editor()>, which might include
the options in the string, for example:

  $sqitch->shell( $sqitch->editor, $sqitch->quote_shell($file) );

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
  $sqitch->spool(\@file_handles, 'sqlite3', 'my.db');

Like run, but spools the contents of one or ore file handle to the standard
input the system command. Returns true on success and throws an exception on
failure.

=head3 C<trace>

=head3 C<trace_literal>

  $sqitch->trace_literal('About to fuzzle the wuzzle.');
  $sqitch->trace('Done.');

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<trace: > prefixed to every line. If it's lower than
3, nothing will be output. C<trace> appends a newline to the end of the
message while C<trace_literal> does not.

=head3 C<debug>

=head3 C<debug_literal>

  $sqitch->debug('Found snuggle in the crib.');
  $sqitch->debug_literal('ITYM "snuggie".');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<debug: > prefixed to every line. If it's lower than
2, nothing will be output. C<debug> appends a newline to the end of the
message while C<debug_literal> does not.

=head3 C<info>

=head3 C<info_literal>

  $sqitch->info('Nothing to deploy (up-to-date)');
  $sqitch->info_literal('Going to frobble the shiznet.');

Send informational message to C<STDOUT> if the verbosity level is 1 or higher,
which, by default, it is. Should be used for normal messages the user would
normally want to see. If verbosity is lower than 1, nothing will be output.
C<info> appends a newline to the end of the message while C<info_literal> does
not.

=head3 C<comment>

=head3 C<comment_literal>

  $sqitch->comment('On database flipr_test');
  $sqitch->comment_literal('Uh-oh...');

Send comments to C<STDOUT> if the verbosity level is 1 or higher, which, by
default, it is. Comments have C<# > prefixed to every line. If verbosity is
lower than 1, nothing will be output. C<comment> appends a newline to the end
of the message while C<comment_literal> does not.

=head3 C<emit>

=head3 C<emit_literal>

  $sqitch->emit('core.editor=emacs');
  $sqitch->emit_literal('Getting ready...');

Send a message to C<STDOUT>, without regard to the verbosity. Should be used
only if the user explicitly asks for output, such as for C<sqitch config --get
core.editor>. C<emit> appends a newline to the end of the message while
C<emit_literal> does not.

=head3 C<vent>

=head3 C<vent_literal>

  $sqitch->vent('That was a misage.');
  $sqitch->vent_literal('This is going to be bad...');

Send a message to C<STDERR>, without regard to the verbosity. Should be used
only for error messages to be printed before exiting with an error, such as
when reverting failed changes. C<vent> appends a newline to the end of the
message while C<vent_literal> does not.

=head3 C<page>

=head3 C<page_literal>

  $sqitch->page('Search results:');
  $sqitch->page("Here we go\n");

Like C<emit()>, but sends the output to a pager handle rather than C<STDOUT>.
Unless there is no TTY (such as when output is being piped elsewhere), in
which case it I<is> sent to C<STDOUT>. C<page> appends a newline to the end of
the message while C<page_literal> does not. Meant to be used to send a lot of
data to the user at once, such as when display the results of searching the
event log:

  $iter = $sqitch->engine->search_events;
  while ( my $change = $iter->() ) {
      $sqitch->page(join ' - ', @{ $change }{ qw(change_id event change) });
  }

=head3 C<warn>

=head3 C<warn_literal>

  $sqitch->warn('Could not find nerble; using nobble instead.');
  $sqitch->warn_literal("Cannot read file: $!\n");

Send a warning messages to C<STDERR>. Warnings will have C<warning: > prefixed
to every line. Use if something unexpected happened but you can recover from
it. C<warn> appends a newline to the end of the message while C<warn_literal>
does not.

=head3 C<prompt>

  my $ans = $sqitch->('Why would you want to do this?', 'because');

Prompts the user for input and returns that input. Pass in an optional default
value for the user to accept or to be used if Sqitch is running unattended. An
exception will be thrown if there is no prompt message or if Sqitch is
unattended and there is no default value.

=head3 C<ask_y_n>

  if ( $sqitch->ask_y_no('Are you sure?', 'y') ) { # do it! }

Prompts the user with a "yes" or "no" question. Returns true for "yes" and
false for "no". Any answer that begins with case-insensitive "y" or "n" will
be accepted as valid. If the user inputs an invalid value three times, an
exception will be thrown. An exception will also be thrown if there is no
message or if the optional default value does not begin with "y" or "n". As
with C<prompt()> an exception will be thrown if Sqitch is running unattended
and there is no default.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2018 iovation Inc.

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
