package App::Sqitch::Command::help;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Pod::Find;
use Mouse;
extends 'App::Sqitch::Command';

our $VERSION = '0.973';

# XXX Add --all at some point, to output a list of all possible commands.

sub execute {
    my ( $self, $command ) = @_;
    $self->find_and_show('sqitch' . ( $command ? "-$command" : 'commands' ));
}

sub find_and_show {
    my ( $self, $look_for ) = (shift, shift);

    my $pod = Pod::Find::pod_where({
        '-inc' => 1,
        '-script' => 1
    }, $look_for ) or hurl {
        ident   => 'help',
        message => __x('No manual entry for {command}', command => $look_for),
        exitval => 1,
    };

    $self->_pod2usage(
        '-input'   => $pod,
        '-verbose' => 2,
        '-exitval' => 0,
        @_,
    );
}

1;

__END__

=head1 Name

App::Sqitch::Command::help - Display help information about Sqitch

=head1 Synopsis

  my $cmd = App::Sqitch::Command::help->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<help> command, you probably want to be
reading C<sqitch-help>. But if you really want to know how the C<help> command
works, read on.

=head1 Interface

=head2 Instance Methods

=head3 C<execute>

  $help->execute($command);

Executes the help command. If a command is passed, the help for that command will
be shown. If it cannot be found, Sqitch will throw an error and exit. If no
command is specified, the the L<Sqitch core documentation|sqitch> will be shown.

=head3 C<find_and_show>

  $help->find_and_show($file, %options);

Does the work of finding the pod file C<$file> and passing it on to
L<Pod::Usage>, along with any additional options for Pod::Usage's constructor.

=head1 See Also

=over

=item L<sqitch-help>

Documentation for the C<help> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2013 iovation Inc.

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
