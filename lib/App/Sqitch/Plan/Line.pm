package App::Sqitch::Plan::Line;

use 5.010;
use utf8;
use namespace::autoclean;
use Moo;
use App::Sqitch::Types qw(Str Plan);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);

our $VERSION = '0.9997';

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has operator => (
    is       => 'ro',
    isa      => Str,
    default  => '',
);

has lspace => (
    is       => 'ro',
    isa      => Str,
    default  => '',
);

has rspace => (
    is       => 'rwp',
    isa      => Str,
    default  => '',
);

has lopspace => (
    is       => 'ro',
    isa      => Str,
    default  => '',
);

has ropspace => (
    is       => 'ro',
    isa      => Str,
    default  => '',
);

has note => (
    is       => 'rw',
    isa      => Str,
    default  => '',
);

after note => sub {
    my $self = shift;
    $self->_set_rspace(' ') if $_[0] && !$self->rspace;
};

has plan => (
    is       => 'ro',
    isa      => Plan,
    weak_ref => 1,
    required => 1,
    handles  => [qw(sqitch project uri target)],
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
    if (my $note = $p->{note}) {
        # Trim and then encode newlines.
        $note =~ s/\A\s+//;
        $note =~ s/\s+\z//;
        $note =~ s/(\\[\\nr])/$unescape{$1}/g;
        $p->{note} = $note;
        $p->{rspace} //= ' ' if $note && $p->{name};
    }
    return $p;
}

sub request_note {
    my ( $self, %p ) = @_;
    my $note = $self->note // '';
    return $note if $note =~ /\S/;

    # Edit in a file.
    require File::Temp;
    my $tmp = File::Temp->new;
    binmode $tmp, ':utf8_strict';
    ( my $prompt = $self->note_prompt(%p) ) =~ s/^/# /gms;
    $tmp->print( "\n", $prompt, "\n" );
    $tmp->close;

    my $sqitch = $self->sqitch;
    $sqitch->shell( $sqitch->editor . ' ' . $sqitch->quote_shell($tmp) );

    open my $fh, '<:utf8_strict', $tmp or hurl add => __x(
        'Cannot open {file}: {error}',
        file  => $tmp,
        error => $!
    );

    $note = join '', grep { $_ !~ /^\s*#/ } <$fh>;
    hurl {
        ident   => 'plan',
        message => __ 'Aborting due to empty note',
        exitval => 1,
    } unless $note =~ /\S/;

    # Trim the note.
    $note =~ s/\A\v+//;
    $note =~ s/\v+\z//;

    # Set the note.
    $self->note($note);
    return $note;
}

sub note_prompt {
    my ( $self, %p ) = @_;
    __x(
        "Write a {command} note.\nLines starting with '#' will be ignored.",
        command => $p{for}
    );
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

sub format_note {
    my $note = shift->note;
    return '' unless length $note;
    $note =~ s/([\r\n\\])/$escape{$1}/g;
    return "# $note";
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
note.

=item C<note>

A note. Does not include the leading C<#>, but does include any white space
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
of a note.

=head3 C<note>

  my $note = $line->note.

Returns the note. Does not include the leading C<#>, but does include any
white space immediate after the C<#> when the plan file is parsed. Returns the
empty string if there is no note.

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

=head3 C<format_note>

  my $note = $line->format_note;

Returns the note formatted for output. That is, with a leading C<#> and
newlines encoded.

=head3 C<as_string>

  my $string = $line->as_string;

Returns the full stringification of the line, suitable for output to a plan
file.

=head3 C<request_note>

  my $note = $line->request_note( for => 'add' );

Request the note from the user. Pass in the name of the command for which the
note is requested via the C<for> parameter. If there is a note, it is simply
returned. Otherwise, an editor will be launched and the user asked to write
one. Once the editor exits, the note will be retrieved from the file, saved,
and returned. If no note was written, an exception will be thrown with an
C<exitval> of 1.

=head3 C<note_prompt>

  my $prompt = $line->note_prompt( for => 'tag' );

Returns a localized string for use in the temporary file created by
C<request_note()>. Pass in the name of the command for which to prompt via the
C<for> parameter.

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

Copyright (c) 2012-2017 iovation Inc.

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
