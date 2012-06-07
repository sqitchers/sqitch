package App::Sqitch::X;

use v5.10.1;
use utf8;
use Moose;
use Sub::Exporter -setup => [qw(hurl)];

our $VERSION = '0.32';

has message => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

with qw(Throwable Role::HasMessage StackTrace::Auto Role::Identifiable::HasIdent);

sub hurl {
    my $throw = __PACKAGE__->can('throw');
    @_ = (__PACKAGE__, ref $_[0] ? $_[0] : (ident => $_[0], message => $_[1]));
    goto $throw;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);
no Moose;

__END__

=head1 Name

App::Sqitch::X - Sqitch Exception class

=head1 Synopsis

Throw:

  use App::Sqitch::X;
  open my $fh, '>', 'foo.txt' or App::Sqitch::X->throw(
      ident   => 'io',
      message => "Cannot open foo.txt: $!"
  );

Hurl:

  use App::Sqitch::X qw(hurl);
  open my $fh, '>', 'foo.txt' or hurl {
      ident   => 'io',
      message => "Cannot open foo.txt: $!"
  };

  open my $fh, '>', 'foo.txt' or hurl io => "Cannot open foo.txt: $!";

=head1 Description

This module provides implements Sqitch exceptions. Exceptions may be thrown by
any part of the code, and, as long as a command is running, they will be
handled, showing the error message to the user.

=head1 Interface

=head2 Class Method

=head3 C<throw()>

  open my $fh, '>', 'foo.txt' or App::Sqitch::X->throw(
      ident   => 'io',
      message => "Cannot open foo.txt: $!"
  );

Throws an exception. The supported parameters include:

=over

=item C<ident>

A non-localized string identifying the type of exception.

=item C<message>

The exception message.

=back

=head2 Function

=head3 C<hurl>

To save yourself some typing, you can import the C<hurl> keyword and pass the
parameters as a hash reference, like so:

  use App::Sqitch::X qw(hurl);
  open my $fh, '>', 'foo.txt' or hurl {
      ident   => 'io',
      message => "Cannot open foo.txt: $!"
  };

More simply, if all you need to pass are the C<ident> and C<message>
parameters, you can pass them as the only arguments to C<hurl()>:

  open my $fh, '>', 'foo.txt' or hurl io => "Cannot open foo.txt: $!";

=head1 Handling Exceptions

use L<Try::Tiny> to do exception handling, like so:

  use Try::Tiny;
  try {
      # ...
  } catch {
      die $_ unless eval { $_->isa('App::Sqitch::X') };
      $sqitch->debug($_->stack_trace->as_string);
      $sqitch->fail($_->message);
  };

Use the C<ident> attribute to determine what category of exception it is, and
take steps as appropriate.

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

