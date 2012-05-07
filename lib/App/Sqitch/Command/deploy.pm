package App::Sqitch::Command::deploy;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Moose;
extends 'App::Sqitch::Command';

our $VERSION = '0.30';

sub execute {
    my $self = shift;
}

1;

__END__

=head1 Name

App::Sqitch::Command::deploy - Deploy Sqitch changes

=head1 Synopsis

  my $cmd = App::Sqitch::Command::deploy->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<deploy> command, you probably want to be
reading C<sqitch-deploy>. But if you really want to know how the C<deploy>
command works, read on.

=head1 Interface

=head2 Instance Methods

=head3 C<execute>

  $deploy->execute;

Executes the deploy command.

=head1 See Also

=over

=item L<sqitch-deploy>

Documentation for the C<deploy> command to the Sqitch command-line client.

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
