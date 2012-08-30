package App::Sqitch::Command::revert;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Moose;
use Moose::Util::TypeConstraints;
use List::Util qw(first);
use namespace::autoclean;
extends 'App::Sqitch::Command';

our $VERSION = '0.923';

has to_target => (
    is  => 'ro',
    isa => 'Str',
);

sub options {
    return qw(
        to-target|to|target=s
    );
}

sub execute {
    my $self   = shift;
    my $engine = $self->sqitch->engine;
    $engine->revert( $self->to_target // shift );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::revert - Revert Sqitch changes from a database

=head1 Synopsis

  my $cmd = App::Sqitch::Command::revert->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<revert> command, you probably want to be
reading C<sqitch-revert>. But if you really want to know how the C<revert> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::revert->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<revert> command.

=head2 Instance Methods

=head3 C<execute>

  $revert->execute;

Executes the revert command.

=head1 See Also

=over

=item L<sqitch-revert>

Documentation for the C<revert> command to the Sqitch command-line client.

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
