package App::Sqitch::Plan::Pragma;

use 5.010;
use utf8;
use namespace::autoclean;
use Moo;
use App::Sqitch::Types qw(Str);
extends 'App::Sqitch::Plan::Line';

our $VERSION = '0.9993';

has value => (
    is       => 'ro',
    isa      => Str,
);

has hspace => (
    is       => 'ro',
    isa      => Str,
    default  => '',
);

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    $p->{value} =~ s/\s+$// if $p->{value};
    $p->{op} //= '';
    return $p;
}

sub format_name {
    my $self = shift;
    return '%' . $self->hspace . $self->name;
}

sub format_value {
    shift->value // '';
}

sub format_content {
    my $self = shift;
    join '', $self->format_name, $self->format_operator, $self->format_value;
}

sub as_string {
    my $self = shift;
    return $self->lspace
         . $self->format_content
         . $self->rspace
         . $self->format_note;
}

1;

__END__

=head1 Name

App::Sqitch::Plan::Pragma.pm - Sqitch deployment plan blank line

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

An App::Sqitch::Plan::Pragma represents a plan file pragma. See
L<App::Sqitch::Plan::Line> for its interface.

=head1 Interface

In addition to the interface inherited from L<App::Sqitch::Plan::Line>,
App::Sqitch::Plan::Line::Pragma adds a few methods of its own.

=head2 Accessors

=head3 C<value>

The value of the pragma.

=head3 C<op>

The operator, including surrounding white space.

=head3 C<hspace>

The horizontal space between the pragma and its value.

=head2 Instance Methods

=head3 C<format_value>

Formats the value for output. If there is no value, an empty string is
returned. Otherwise the value is returned as-is.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2015 iovation Inc.

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
