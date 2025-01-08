package App::Sqitch::Role::ConnectingCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use App::Sqitch::Types qw(ArrayRef);

# VERSION

requires 'options';
requires 'configure';
requires 'target_params';

has _params => (
    is  => 'ro',
    isa => ArrayRef,
    default => sub { [] },
);

around options => sub {
    my $orig = shift;
    return $orig->(@_), qw(
        registry=s
        client|db-client=s
        db-name|d=s
        db-user|db-username|u=s
        db-host|h=s
        db-port|p=i
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;

    # Grab the options we're responsible for.
    my @params = (
        (exists $opt->{db_user}  ? ('user',    => delete $opt->{db_user})  : ()),
        (exists $opt->{db_host}  ? ('host',    => delete $opt->{db_host})  : ()),
        (exists $opt->{db_port}  ? ('port',    => delete $opt->{db_port})  : ()),
        (exists $opt->{db_name}  ? ('dbname'   => delete $opt->{db_name})  : ()),
        (exists $opt->{registry} ? ('registry' => delete $opt->{registry}) : ()),
        (exists $opt->{client}   ? ('client'   => delete $opt->{client})   : ()),
    );

    # Let the command take care of its options.
    my $params = $class->$orig($config, $opt);

    # Hang on to the target parameters.
    $params->{_params} = \@params;
    return $params;
};

around target_params => sub {
    my ($orig, $self) = (shift, shift);
    return $self->$orig(@_), @{ $self->_params };
};

1;

__END__

=head1 Name

App::Sqitch::Role::ConnectingCommand - A command that connects to a target

=head1 Synopsis

  package App::Sqitch::Command::deploy;
  extends 'App::Sqitch::Command';
  with 'App::Sqitch::Role::ConnectingCommand';

=head1 Description

This role encapsulates the options and target parameters required by commands
that connect to a database target.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::deploy->options;

Adds database connection options.

=head3 C<configure>

Configures the options used for target parameters.

=head2 Instance Methods

=head3 C<target_params>

Returns a list of parameters to be passed to App::Sqitch::Target's C<new>
and C<all_targets> methods.
=head1 See Also

=over

=item L<App::Sqitch::Command::deploy>

The C<deploy> command deploys changes to a database.

=item L<App::Sqitch::Command::revert>

The C<revert> command reverts changes from a database.

=item L<App::Sqitch::Command::log>

The C<log> command shows the event log for a database.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2025 David E. Wheeler, 2012-2021 iovation Inc.

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
