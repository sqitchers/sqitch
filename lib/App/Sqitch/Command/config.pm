package App::Sqitch::Command::config;

use v5.10;
use strict;
use warnings;
use utf8;
use Carp;
use parent 'App::Sqitch::Command';

our $VERSION = '0.10';

sub execute {
    my $self = shift;
}

1;

__END__

=head1 Name

App::Sqitch::Command::config - Get and set project or global Sqitch options

=head1 Synopsis

  my $cmd = App::Sqitch::Command::config->new(\%params);
  $cmd->execute;

=head1 Description

You can query/set/replace/unset Sqitch options with this command. The name is
actually the section and the key separated by a dot, and the value will be
escaped.

=head1 Interface

=head2 Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<execute>

  $config->execute;

Executes the config command.

=head1 See Also

=over

=item L<sqitch-config>

Help for the C<config> command to the Sqitch command-line client.

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

