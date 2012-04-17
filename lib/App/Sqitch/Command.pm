package App::Sqitch::Command;

use v5.10;
use strict;
use warnings;
use utf8;
use Carp;
use Try::Tiny;
use Hash::Merge 'merge';
use parent 'Class::Accessor::Fast';

__PACKAGE__->mk_ro_accessors(qw(
    sqitch
));

sub load {
    my ($class, $p) = @_;

    # We should have a command.
    croak qq{No command name passed to $class->load} unless $p->{command};

    # Load the command class.
    my $pkg = __PACKAGE__ . "::$p->{command}";
    try {
        eval "require $pkg" or die $@;
    } catch {
        # Just die if something choked.
        die $_ unless /^Can't locate/;

        # Suggest help if it's not a valid command.
        __PACKAGE__->new({ sqitch => $p->{sqitch} })->help(
            qq{"$p->{command}" is not a valid command.}
        );
    };

    # Merge the command-line options and configuration parameters
    my $params = Hash::Merge->new->merge(
        $p->{config},
        $class->_parse_opts($p->{args}),
    );

    # Instantiate and return the command.
    $params->{sqitch} = $p->{sqitch};
    return $pkg->new($params);
}

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);

    # We should have a Sqitch object.
    croak(qq{No "sqitch" parameter passed to $class->new}) unless $self->sqitch;
    croak $self->sqitch . ' is not an App::Sqitch object'
        unless eval { $self->sqitch->isa('App::Sqitch' )};

    # We're in good shape.
    return $self;
}

sub verbosity {
    shift->sqitch->verbosity;
}

sub _parse_opts {
    my ($class, $args) = @_;
    return {};
}

sub _prepend {
    my $prefix = shift;
    my $msg = join '', map { $_  // '' } @_;
    $msg =~ s/^/$prefix /gms;
    return $msg;
}

sub execute {
    my $self = shift;
    croak(
        'The execute() method must be called from a subclass of ',
        __PACKAGE__
    ) if ref $self eq __PACKAGE__;

    croak(
        'The execute() method has not been overridden in ',
        ref $self
    );
}

sub trace {
    my $self = shift;
    print _prepend 'trace:', @_ if $self->verbosity > 2
}

sub debug {
    my $self = shift;
    print _prepend 'debug:', @_ if $self->verbosity > 1
}

sub info {
    my $self = shift;
    print @_ if $self->verbosity;
}

sub comment {
    my $self = shift;
    print _prepend '#', @_ if $self->verbosity;
}

sub warn {
    my $self = shift;
    print STDERR _prepend 'warning:', @_;
}

sub fail {
    my $self = shift;
    print STDERR _prepend 'fatal:', @_;
    exit 1;
}

sub help {
    my $self = shift;
    use File::Basename;
    my $bn = File::Basename::basename($0);
    print STDERR _prepend("$bn:", @_), " See $bn --help$/";
    exit 1;
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

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Command->load( deploy => \%params );

A factory method for instantiating Sqitch commands. It first tries to
load the subclass for the specified command, then calls its C<new>
constructor with specified parameters, and then returns it.

=head3 C<new>

  my $cmd = App::Sqitch::Command->new(\%params);

Instantiates and returns a App::Sqitch::Command object. This method is
designed to be overridden by subclasses, as an instance of the base
App::Sqitch::Command class is probably useless. Call C<new> on a subclass, or
use C<init>, instead.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the command. Commands may
access its properties in order to manage global state.

=head2 Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use. The exception is C<execute>, which must be overridden in all subclasses.

=head3 C<execute>

  $config->execute;

Executes the command. This is the method that does the work of the command.
Must be overridden in all subclasses. Dies if the method is not overridden for
the object on which it is called, or if it is called against a base
App::Sqitch::Command object.

=head3 C<verbosity>

  my $verbosity = $cmd->verbosity;

Returns the verbosity level.

=head3 C<trace>

  $cmd->trace('About to fuzzle the wuzzle.');

Send trace information to C<STDOUT> if the verbosity level is 3 or higher.
Trace messages will have C<TRACE: > prefixed to every line. If it's lower than
3, nothing will be output.

=head3 C<debug>

  $cmd->debug('Found snuggle in the crib.');

Send debug information to C<STDOUT> if the verbosity level is 2 or higher.
Debug messages will have C<DEBUG: > prefixed to every line. If it's lower than
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

=head3 C<warn>

  $cmd->warn('Could not find nerble; using nobble instead.');

Send a warning messages to C<STDERR>. Use if something unexpected happened but
you can recover from it.

=head3 C<fail>

  $cmd->fail('File or directory "foo" not found.');

Send a failure message to C<STDERR> and exit. Use if something unexpected
happened and you cannot recover from it.

=head3 C<help>

  $cmd->help('"foo" is not a valid command.');

Sends messages to C<STDERR> and exists with an additional message to "See
sqitch --help". Use if the user has misused the app.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

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

