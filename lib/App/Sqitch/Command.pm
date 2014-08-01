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
use App::Sqitch::Types qw(Sqitch);

our $VERSION = '0.996';

has sqitch => (
    is       => 'ro',
    isa      => Sqitch,
    required => 1,
    handles  => [qw(
        plan
        engine
        config_for_target
        config_for_target_strict
        engine_for_target
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

sub command {
    my $class = ref $_[0] || shift;
    return '' if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    $class =~ s/_/-/g;
    return $class;
}

sub load {
    my ( $class, $p ) = @_;
    my $sqitch = $p->{sqitch};

    # We should have a command.
    $class->usage unless $p->{command};
    ( my $cmd = $p->{command} ) =~ s/-/_/g;

    # Load the command class.
    my $pkg = __PACKAGE__ . "::$cmd";
    try {
        eval "require $pkg" or die $@;
    }
    catch {
        # Emit the original error for debugging.
        $sqitch->debug($_);

        # Suggest help if it's not a valid command.
        hurl {
            ident   => 'command',
            exitval => 1,
            message => __x(
                '"{command}" is not a valid command',
                command => $cmd,
            ),
        };
    };

    # Merge the command-line options and configuration parameters
    my $params = $pkg->configure(
        $p->{config},
        $pkg->_parse_opts( $p->{args} )
    );

    # Instantiate and return the command.
    $params->{sqitch} = $sqitch;
    return $pkg->new($params);
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
        %params
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

sub parse_args {
    my $self   = shift;
    my $plan   = $self->plan;
    my $config = $self->sqitch->config;
    require URI;

    my %ret    = (
        changes => [],
        targets => [],
        unknown => [],
    );
    for my $arg (@_) {
        my $ref = $plan->contains($arg)                   ? $ret{changes}
                : URI->new($arg)->isa('URI::db')          ? $ret{targets}
                : $config->get( key => "target.$arg.uri") ? $ret{targets}
                :                                           $ret{unknown};
        push @{ $ref } => $arg;
    }

    return %ret;
}

__PACKAGE__->meta->make_immutable;
no Moo;

__END__

=head1 Name

App::Sqitch::Command - Sqitch Command support

=head1 Synopsis

  my $cmd = App::Sqitch::Command->load( deploy => \%params );
  $cmd->run;

=head1 Description

App::Sqitch::Command is the base class for all Sqitch commands.

=head1 Interface

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

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Command->load( \%params );

A factory method for instantiating Sqitch commands. It loads the subclass for
the specified command, uses the options returned by C<options> to parse
command-line options, calls C<configure> to merge configuration with the
options, and finally calls C<new> with the resulting hash. Supported parameters
are:

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

=head3 C<parse_args>

  my @parsed_args = $cmd->parse_args(@args);

Examines each argument to determine whether it's a known change spec or
target. Returns a list of two-value array references, one for each argument
passed. For each array reference, the first item is the argument type, either
"change", "target", or "unknown", and the second item is the original value.
Useful for commands that take a number of parameters where the order may be
mixed.

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

  $iter = $sqitch->engine->search_events;
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

Copyright (c) 2012-2014 iovation Inc.

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

