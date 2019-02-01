package App::Sqitch::Command;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Hash::Merge 'merge';
use Moo;
use App::Sqitch::Types qw(Sqitch Target);

use SemVer; our $VERSION = SemVer->new('1.0.0-a1');

use constant ENGINES => qw(
    pg
    sqlite
    mysql
    oracle
    firebird
    vertica
    exasol
    snowflake
);

has sqitch => (
    is       => 'ro',
    isa      => Sqitch,
    required => 1,
    handles  => [qw(
        run
        shell
        quote_shell
        capture
        probe
        verbosity
        trace
        trace_literal
        debug
        debug_literal
        info
        info_literal
        comment
        comment_literal
        emit
        emit_literal
        vent
        vent_literal
        warn
        warn_literal
        page
        page_literal
        prompt
        ask_y_n
    )],
);

has default_target => (
    is      => 'ro',
    isa     => Target,
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $sqitch = $self->sqitch;
        my @params = $self->target_params;
        unless (
               $sqitch->config->get(key => 'core.engine')
            || $sqitch->config->get(key => 'core.target')
        ) {
            # No specified engine, so specify an engineless URI.
            require URI::db;
            unshift @params, uri => URI::db->new('db:');
        }
        require App::Sqitch::Target;
        return App::Sqitch::Target->new(@params);
    },
);

sub command {
    my $class = ref $_[0] || shift;
    return '' if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    $class =~ s/_/-/g;
    return $class;
}

sub class_for {
    my ( $class, $sqitch, $cmd ) = @_;

    $cmd =~ s/-/_/g;

    # Load the command class.
    my $pkg = __PACKAGE__ . "::$cmd";
    eval "require $pkg; 1" or do {
        # Emit the original error for debugging.
        $sqitch->debug($@);
        return undef;
    };
    return $pkg;
}

sub load {
    my ( $class, $p ) = @_;
    # We should have a command.
    my $cmd = delete $p->{command} or $class->usage;
    my $pkg = $class->class_for($p->{sqitch}, $cmd) or hurl {
        ident   => 'command',
        exitval => 1,
        message => __x(
            '"{command}" is not a valid command',
            command => $cmd,
        ),
    };
    $pkg->create($p);
}

sub create {
    my ( $class, $p ) = @_;

    # Merge the command-line options and configuration parameters
    my $params = $class->configure(
        $p->{config},
        $class->_parse_opts( $p->{args} )
    );

    # Instantiate and return the command.
    $params->{sqitch} = $p->{sqitch};
    return $class->new($params);
}

sub configure {
    my ( $class, $config, $options ) = @_;

    return Hash::Merge->new->merge(
        $options,
        $config->get_section( section => $class->command ),
    );
}

sub options {
    return;
}

sub _parse_opts {
    my ( $class, $args ) = @_;
    return {} unless $args && @{$args};

    my %opts;
    Getopt::Long::Configure(qw(bundling no_pass_through));
    Getopt::Long::GetOptionsFromArray( $args, \%opts, $class->options )
        or $class->usage;

    # Convert dashes to underscores.
    for my $k (keys %opts) {
        next unless ( my $nk = $k ) =~ s/-/_/g;
        $opts{$nk} = delete $opts{$k};
    }

    return \%opts;
}

sub _bn {
    require File::Basename;
    File::Basename::basename($0);
}

sub _pod2usage {
    my ( $self, %params ) = @_;
    my $command = $self->command;
    require Pod::Find;
    require Pod::Usage;
    my $bn = _bn;
    my $find_pod = sub {
        Pod::Find::pod_where({ '-inc' => 1, '-script' => 1 }, shift );
    };
    $params{'-input'} ||= $find_pod->("$bn-$command")
                      ||  $find_pod->("sqitch-$command")
                      ||  $find_pod->($bn)
                      ||  $find_pod->('sqitch')
                      ||  $find_pod->(ref $self || $self)
                      ||  $find_pod->(__PACKAGE__);
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Synopsis|Options))',
        '-exitval'  => 2,
        %params,
    );
}

sub execute {
    my $self = shift;
    hurl(
        'The execute() method must be called from a subclass of '
        . __PACKAGE__
    ) if ref $self eq __PACKAGE__;

    hurl 'The execute() method has not been overridden in ' . ref $self;
}

sub usage {
    my $self = shift;
    require Pod::Find;
    my $upod = _bn . '-' . $self->command . '-usage';
    $self->_pod2usage(
        '-input' => Pod::Find::pod_where( { '-inc' => 1 }, $upod ) || undef,
        '-message' => join '', @_
    );
}

sub target_params {
    return (sqitch => shift->sqitch);
}

sub parse_args {
    my ($self, %p) = @_;
    my $config = $self->sqitch->config;
    my @params = $self->target_params;

    # Load the specified or default target.
    require App::Sqitch::Target;
    my $deftarget_err;
    my $target = try {
        App::Sqitch::Target->new( @params, name => $p{target} )
    } catch {
        # Die if a target was specified; otherwise keep the error for later.
        die $_ if $p{target};
        $deftarget_err = $_;
        undef;
    };

    # Set up the default results.
    my (%seen, %target_for);
    my %rec = map { $_ => [] } qw(targets unknown);
    $rec{changes} = [] unless $p{no_changes};
    if ($p{target}) {
        push @{ $rec{targets} } => $target;
        $seen{$target->name}++;
    }

    # Iterate over the argsx to look for changes, engines, plans, or targets.
    my %engines = map { $_ => 1 } ENGINES;
    for my $arg (@{ $p{args} }) {
        if ( !$p{no_changes} && $target && -e $target->plan_file && $target->plan->contains($arg) ) {
            # A change.
            push @{ $rec{changes} } => $arg;
        } elsif ($config->get( key => "target.$arg.uri") || URI->new($arg)->isa('URI::db')) {
            # A target. Instantiate and keep for subsequente change searches.
            $target = App::Sqitch::Target->new( @params, name => $arg );
            push @{ $rec{targets} } => $target unless $seen{$target->name}++;
        } elsif ($engines{$arg}) {
            # An engine. Add its target.
            my $name = $config->get(key => "engine.$arg.target") || "db:$arg:";
            $target = App::Sqitch::Target->new( @params, name => $name );
            push @{ $rec{targets} } => $target unless $seen{$target->name}++;
        } elsif (-e $arg) {
            # Maybe it's a plan file?
            %target_for = map {
                $_->plan_file => $_
            } reverse App::Sqitch::Target->all_targets(@params) unless %target_for;
            if ($target_for{$arg}) {
                # It *is* a plan file.
                $target = $target_for{$arg};
                push @{ $rec{targets} } => $target unless $seen{$target->name}++;
            } else {
                # Nah, who knows.
                push @{ $rec{unknown} } => $arg;
            }
        } else {
            # Who knows?
            push @{ $rec{unknown} } => $arg;
        }
    }

    # Replace missing names with unknown values.
    my @names = map { $_ || shift @{ $rec{unknown} } } @{ $p{names} || [] };

    # Die on unknowns.
    if (my @unknown = @{ $rec{unknown} } ) {
        hurl $self->command => __nx(
            'Unknown argument "{arg}"',
            'Unknown arguments: {arg}',
            scalar @unknown,
            arg => join ', ', @unknown
        );
    }

    # Figure out what targets to access. Use default unless --all.
    my @targets = @{ $rec{targets} };
    if ($p{all}) {
        # Got --all.
        hurl $self->command => __(
            'Cannot specify both --all and engine, target, or plan arugments'
        ) if @targets;
        @targets = App::Sqitch::Target->all_targets(@params );
    } elsif (!@targets) {
        # Use all if tag.all is set, otherwise just the default.
        my $key = $self->command . '.all';
        @targets = $self->sqitch->config->get(key => $key, as => 'bool')
            ? App::Sqitch::Target->all_targets(@params )
            : do {
                # Fall back on the default unless it's invalid.
                die $deftarget_err if $deftarget_err;
                ($target)
            }
    }

    return (@names, \@targets, $rec{changes});
}

1;

__END__

=head1 Name

App::Sqitch::Command - Sqitch Command support

=head1 Synopsis

  my $cmd = App::Sqitch::Command->load( deploy => \%params );
  $cmd->run;

=head1 Description

App::Sqitch::Command is the base class for all Sqitch commands.

=head1 Interface

=head2 Constants

=head3 C<ENGINES>

Returns the list of supported engines, currently:

=over

=item * C<firebird>

=item * C<mysql>

=item * C<oracle>

=item * C<pg>

=item * C<sqlite>

=item * C<vertica>

=item * C<exasol>

=item * C<snowflake>

=back

=head2 Class Methods

=head3 C<options>

  my @spec = App::Sqitch::Command->options;

Returns a list of L<Getopt::Long> options specifications. When C<load> loads
the class, any options passed to the command will be parsed using these
values. The keys in the resulting hash will be the first part of each option,
with dashes converted to underscores. This hash will be passed to C<configure>
along with a L<App::Sqitch::Config> object for munging into parameters to be
passed to the constructor.

Here's an example excerpted from the C<config> command:

  sub options {
      return qw(
          get
          unset
          list
          global
          system
          config-file=s
      );
  }

This will result in hash keys with the same names as each option except for
C<config-file=s>, which will be named C<config_file>.

=head3 C<configure>

  my $params = App::Sqitch::Command->configure($config, $options);

Takes two arguments, an L<App::Sqitch::Config> object and the hash of
command-line options as specified by C<options>. The returned hash should be
the result of munging these two objects into a hash reference of parameters to
be passed to the command subclass constructor.

By default, this method converts dashes to underscores in command-line options
keys, and then merges the configuration values with the options, with the
command-line options taking priority. You may wish to override this method to
do something different.

=head3 C<class_for>

  my $subclass = App::Sqitch::Command->subclass_for($sqitch, $cmd_name);

This method attempts to load the subclass of App::Sqitch::Commmand that
corresponds to the command name. Returns C<undef> and sends errors to the
C<debug> method of the <$sqitch> object if no such subclass can
be loaded.

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Command->load( \%params );

A factory method for instantiating Sqitch commands. It loads the subclass for
the specified command and calls C<create> to instantiate and return an
instance of the subclass. Sends error messages to the C<debug> method of the
C<sqitch> parameter and throws an exception if the subclass does not exist or
cannot be loaded. Supported parameters are:

=over

=item C<sqitch>

The App::Sqitch object driving the whole thing.

=item C<config>

An L<App::Sqitch::Config> representing the current application configuration
state.

=item C<command>

The name of the command to be executed.

=item C<args>

An array reference of command-line arguments passed to the command.

=back

=head3 C<create>

  my $pkg = App::Sqitch::Command->class_for( $sqitch, $cmd_name )
      or die "No such command $cmd_name";
  my $cmd = $pkg->create({
      sqitch => $sqitch,
      config => $config,
      args   => \@ARGV,
  });

Creates and returns a new object for a subclass of App::Sqitch::Command. It
parses options from the C<args> parameter, calls C<configure> to merge
configuration with the options, and finally calls C<new> with the resulting
hash. Supported parameters are the same as for C<load> except for the
C<command> parameter, which will be ignored.

=head3 C<new>

  my $cmd = App::Sqitch::Command->new(%params);

Instantiates and returns a App::Sqitch::Command object. This method is not
designed to be overridden by subclasses; they should implement
L<C<BUILDARGS>|Moo::Manual::Construction/BUILDARGS> or
L<C<BUILD>|Moo::Manual::Construction/BUILD>, instead.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the command. Commands may
access its properties in order to manage global state.

=head2 Overridable Instance Methods

These methods should be overridden by all subclasses.

=head3 C<execute>

  $cmd->execute;

Executes the command. This is the method that does the work of the command.
Must be overridden in all subclasses. Dies if the method is not overridden for
the object on which it is called, or if it is called against a base
App::Sqitch::Command object.

=head3 C<command>

  my $command = $cmd->command;

The name of the command. Defaults to the last part of the package name, so as
a rule you should not need to override it, since it is that string that Sqitch
uses to find the command class.

=head2 Utility Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<default_target>

  my $target = $cmd->default_target;

This method returns the default target. It should only be used by commands
that don't use a C<parse_args()> to find and load a target.

This method should always return a target option, never C<undef>. If the
C<core.engine> configuration option has been set, then the target will support
that engine. In the latter case, if C<engine.$engine.target> is set, that
value will be used. Otherwise, the returned target will have a URI of C<db:>
and no associated engine; the C<engine> method will throw an exception. This
behavior should be fine for commands that don't need to load the engine.

=head3 C<parse_args>

  my ($name1, $name2, $targets, $changes) = $cmd->parse_args(
    names  => \@names,
    target => $target_name,
    args   => \@args
  );

Examines each argument to determine whether it's a known change spec or
identifies a target or engine. Unrecognized arguments will replace false
values in the C<names> array reference. Any remaining unknown arguments will
trigger an error.

Returns a list consisting all the desired names, followed by an array
reference of target objects and an array reference of change specs.

This method is useful for commands that take a number of arguments where the
order may be mixed.

The supported parameters are:

=over

=item C<args>

An array reference of the command arguments.

=item C<target>

The name of a target, if any. Useful for commands that offer their own
C<--target> option. This target will be the default target, and the first
returned in the targets array.

=item C<names>

An array reference of names. If any is false, its place will be taken by an
otherwise unrecognized argument. The number of values in this array reference
determines the number of values returned as names in the return values. Such
values may still be false or undefined; it's up to the caller to decide what
to do about that.

=item C<all>

In the event that no targets are recognized (or changes that implicitly
recognize the default target), if this parameter is true, then all known
targets from the configuration will be returned.

=item C<no_changes>

If true, the parser will not check to see if any argument corresponds to a
change. The last value returned will be C<undef> instead of the usual array
reference. Any argument that might have been recognized as a change will
instead be included in either the C<targets> array -- if it's recognized as a
target -- or used to set names to return. Any remaining are considered
unknown arguments and will result in an exception.

=back

If a target parameter is passed, it will always be instantiated and returned
as the first item in the "target" array, and arguments recognized as changes
in the plan associated with that target will be returned as changes.

If no target is passed or appears in the arguments, a default target will be
instantiated based on the command-line options and configuration. Unlike the
target returned by C<default_target>, this target B<must> have an associated
engine specified by the configuration. This is on the assumption that it will
be used by commands that require an engine to do their work. Of course, any
changes must be recognized from the plan associated with this target.

Changes are only recognized if they're found in the plan of the target that
precedes them. If no target precedes them, the target specified by the
C<target> parameter or the default target will be searched. Such changes can
be specified in any way documented in L<sqitchchanges>.

Targets may be recognized by any one of these types of arguments:

=over

=item * Target Name

=item * Database URI

=item * Engine Name

=item * Plan File

=back

In the case of plan files, C<parse_args()> will return the first target it
finds for that plan file, even if multiple targets use the same plan file. The
order of precedence for this determination is the default project target,
followed by named targets, then engine targets.

=head3 C<target_params>

  my $target = App::Sqitch::Target->new( $cmd->target_params );

Returns a list of parameters suitable for passing to the C<new> or
C<all_targets> constructors of App::Sqitch::Target.

=head3 C<run>

  $cmd->run('echo hello');

Runs a system command and waits for it to finish. Throws an exception on
error.

=head3 C<capture>

  my @files = $cmd->capture(qw(ls -lah));

Runs a system command and captures its output to C<STDOUT>. Returns the output
lines in list context and the concatenation of the lines in scalar context.
Throws an exception on error.

=head3 C<probe>

  my $git_version = $cmd->capture(qw(git --version));

Like C<capture>, but returns just the C<chomp>ed first line of output.

=head3 C<verbosity>

  my $verbosity = $cmd->verbosity;

Returns the verbosity level.

=head3 C<trace>

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<trace: > prefixed to every line. If it's lower than
3, nothing will be output.

=head3 C<debug>

  $cmd->debug('Found snuggle in the crib.');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<debug: > prefixed to every line. If it's lower than
2, nothing will be output.

=head3 C<info>

  $cmd->info('Nothing to deploy (up-to-date)');

Send informational message to C<STDOUT> if the verbosity level is 1 or higher,
which, by default, it is. Should be used for normal messages the user would
normally want to see. If verbosity is lower than 1, nothing will be output.

=head3 C<comment>

  $cmd->comment('On database flipr_test');

Send comments to C<STDOUT> if the verbosity level is 1 or higher, which, by
default, it is. Comments have C<# > prefixed to every line. If verbosity is
lower than 1, nothing will be output.

=head3 C<emit>

  $cmd->emit('core.editor=emacs');

Send a message to C<STDOUT>, without regard to the verbosity. Should be used
only if the user explicitly asks for output, such as for
C<sqitch config --get core.editor>.

=head3 C<vent>

  $cmd->vent('That was a misage.');

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

  $iter = $engine->search_events;
  while ( my $change = $iter->() ) {
      $cmd->page(join ' - ', @{ $change }{ qw(change_id event change) });
  }

=head3 C<warn>

  $cmd->warn('Could not find nerble; using nobble instead.');

Send a warning messages to C<STDERR>. Warnings will have C<warning: > prefixed
to every line. Use if something unexpected happened but you can recover from
it.

=head3 C<usage>

  $cmd->usage('Missing "value" argument');

Sends the specified message to C<STDERR>, followed by the usage sections of
the command's documentation. Those sections may be named "Name", "Synopsis",
or "Options". Any or all of these will be shown. The doc used to display them
will be the first found of:

=over

=item C<sqitch-$command-usage>

=item C<sqitch-$command>

=item C<sqitch>

=item C<App::Sqitch::Command::$command>

=item C<App::Sqitch::Command>

=back

For an ideal usage messages, C<sqitch-$command-usage.pod> should be created by
all command subclasses.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

=back

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
