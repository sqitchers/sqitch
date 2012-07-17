package App::Sqitch::Plan::Line;

use v5.10.1;
use utf8;
use namespace::autoclean;
use Moose;
use Moose::Meta::Attribute::Native;

has name => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has operator => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has lspace => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has rspace => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has lopspace => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has ropspace => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has comment => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has plan => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan',
    weak_ref => 1,
    required => 1,
    handles  => [qw(sqitch)],
);

my %escape = (
    "\n" => '\\n',
    "\r" => '\\r',
    '\\' => '\\\\',
);

my %unescape = reverse %escape;

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    $p->{comment} =~ s/(\\[\\nr])/$unescape{$1}/g if $p->{comment};
    return $p;
}

sub format_name {
    shift->name;
}

sub format_operator {
    my $self = shift;
    join '', $self->lopspace, $self->operator, $self->ropspace;
}

sub format_content {
    my $self = shift;
    join '', $self->format_operator, $self->format_name;
}

sub format_comment {
    my $comment = shift->comment;
    return '' unless length $comment;
    $comment =~ s/([\r\n\\])/$escape{$1}/g;
    return "# $comment";
}

sub as_string {
    my $self = shift;
    return $self->lspace
         . $self->format_content
         . $self->rspace
         . $self->format_comment;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Line - Sqitch deployment plan line

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

An App::Sqitch::Plan::Line represents a single line from a Sqitch plan file.
Each object managed by an L<App::Sqitch::Plan> object is derived from this
class. This is actually an abstract base class. See
L<App::Sqitch::Plan::Change>, L<App::Sqitch::Plan::Tag>, and
L<App::Sqitch::Plan::Blank> for concrete subclasses.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::Line->new(%params);

Instantiates and returns a App::Sqitch::Plan::Line object. Parameters:

=over

=item C<plan>

The L<App::Sqitch::Plan> object with which the line is associated.

=item C<name>

The name of the line. Should be empty for blank lines. Tags names should
not include the leading C<@>.

=item C<lspace>

The white space from the beginning of the line, if any.

=item C<lopspace>

The white space to the left of the operator, if any.

=item C<operator>

An operator, if any.

=item C<ropspace>

The white space to the right of the operator, if any.

=item C<rspace>

The white space after the name until the end of the line or the start of a
comment.

=item C<comment>

A comment. Does not include the leading C<#>, but does include any white space
immediate after the C<#> when the plan file is parsed.

=back

=head2 Accessors

=head3 C<plan>

  my $plan = $line->plan;

Returns the plan object with which the line object is associated.

=head3 C<name>

  my $name = $line->name;

Returns the name of the line. Returns an empty string if there is no name.

=head3 C<lspace>

  my $lspace = $line->lspace.

Returns the white space from the beginning of the line, if any.

=head3 C<rspace>

  my $rspace = $line->rspace.

Returns the white space after the name until the end of the line or the start
of a comment.

=head3 C<comment>

  my $comment = $line->comment.

Returns the comment. Does not include the leading C<#>, but does include any
white space immediate after the C<#> when the plan file is parsed. Returns the
empty string if there is no comment.

=head2 Instance Methods

=head3 C<format_name>

  my $formatted_name = $line->format_name;

Returns the name of the line properly formatted for output. For
L<tags|App::Sqitch::Plan::Tag>, it's the name with a leading C<@>. For all
other lines, it is simply the name.

=head3 C<format_operator>

  my $formatted_operator = $line->format_operator;

Returns the formatted representation of the operator. This is just the
operator an its associated white space. If neither the operator nor its white
space exists, an empty string is returned. Used internally by C<as_string()>.

=head3 C<format_content>

  my $formatted_content $line->format_content;

Formats and returns the main content of the line. This consists of an operator
and its associated white space, if any, followed by the formatted name.

=head3 C<format_comment>

  my $comment = $line->format_comment;

Returns the comment formatted for output. That is, with a leading C<#>.

=head3 C<as_string>

  my $string = $line->as_string;

Returns the full stringification of the line, suitable for output to a plan
file.

=head1 See Also

=over

=item L<App::Sqitch::Plan>

Class representing a plan.

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
