package App::Sqitch::Plan::Directive;

use v5.10.1;
use utf8;
use namespace::autoclean;
use parent 'App::Sqitch::Plan::Line';
use Moose;

has '+name' => ( default => '' );

has value => (
    is       => 'ro',
    isa      => 'Str',
    required => 0,
);

has op => (
    is       => 'ro',
    isa      => 'Str',
    required => 0,
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
    return '% ' . $self->name;
}

sub format_value {
    shift->value // '';
}

sub stringify {
    my $self = shift;
    return $self->lspace
         . $self->format_name
         . $self->op
         . $self->format_value
         . $self->rspace
         . $self->format_comment;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Directive.pm - Sqitch deployment plan blank line

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->stringify;
  }

=head1 Description

An App::Sqitch::Plan::Directive represents a plan file directive. See
L<App::Sqitch::Plan::Line> for its interface. The only difference is that the
C<name> is always an empty string.

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
