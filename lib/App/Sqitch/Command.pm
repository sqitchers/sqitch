package App::Sqitch::Command;

use v5.10;
use strict;
use warnings;
use utf8;
use parent 'Class::Accessor::Fast';

__PACKAGE__->mk_ro_accessors(qw(
    core
));

sub load {
    my ($class, $command, $params) = @_;
}

1;

__END__

=head1 Name

App::Sqitch::Command - Sqitch Command support

=head1 Synopsis

  my $cmd = App::Sqitch::Command->load(
      command => 'deploy',
      core    => $sqitch,
      params  => \%params,
  );

  $cmd->run;

=head1 Description

App::Sqitch::Command is the base class for all Sqitch commands.

=head1 Interface

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Command->load({
      command => 'deploy',
      core    => $sqitch,
      params  => \%params,
  });

A factory method for instantiating Sqitch commands. It first tries to
load the subclass for the specified command, then calls its C<new>
constructor with specified parameters, and then returns it.

=head3 C<new>

  my $cmd = App::Sqitch::Command->new(\%params);

Instantiates and returns a App::Sqitch::Command object. This method is
designed to be overridden by subclasses, as an instance of the base
App::Sqitch::Command class is probably useless. Call C<new> on a subclass, or
use C<init>, instead.

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

