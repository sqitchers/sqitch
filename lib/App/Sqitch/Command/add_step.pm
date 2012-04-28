package App::Sqitch::Command::add_step;

use v5.10.1;
use strict;
use warnings;
use utf8;
use parent 'App::Sqitch::Command';

our $VERSION = '0.12';

sub options {
    return qw(
        requires|r=s
        conflicts|c=s
        set|s=s@
        template-directory=s
        deploy-template=s
        revert-template=s
        test-template=s
        deploy!
        revert!
        test!
    );
}

sub execute {
    my ($self, $command, $name) = @_;
    $self->usage unless defined $name;
}

1;

__END__

=head1 Name

App::Sqitch::Command::add_step - Add a new deployment step

=head1 Synopsis

  my $cmd = App::Sqitch::Command::add_step->new(%params);
  $cmd->execute;

=head1 Description

Adds a new deployment step. This will result in the creation of a scripts
in the deploy, revert, and test directories. The scripts are based on
templates in F<~/sqitch/templates/>.

=head1 Interface

=head2 Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<options>

  my @opts = App::Sqitch::Command::add_step->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<add_step> command.

=head3 C<execute>

  $add_step->execute($command);

Executes the C<add-step> command.

=head1 See Also

=over

=item L<sqitch-add-step>

Documentation for the C<add-step> command to the Sqitch command-line client.

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
