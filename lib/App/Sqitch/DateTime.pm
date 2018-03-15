package App::Sqitch::DateTime;

use 5.010;
use strict;
use warnings;
use utf8;
use parent 'DateTime';
use DateTime 1.04;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use List::Util qw(first);

our $VERSION = '0.9997';

sub as_string_formats {
    return qw(
        raw
        iso
        iso8601
        rfc
        rfc2822
        full
        long
        medium
        short
    );
}

sub validate_as_string_format {
    my ( $self, $format ) = @_;
    hurl datetime => __x(
        'Unknown date format "{format}"',
        format => $format
    ) unless (first { $format eq $_ } $self->as_string_formats)
          || $format =~ /^(?:cldr|strftime):/;
    return $self;
}

sub as_string {
    my ( $self, %opts ) = @_;
    my $format = $opts{format} || 'raw';
    my $dt     = $self->clone;

    if ($format eq 'raw') {
        $dt->set_time_zone('UTC');
        return $dt->iso8601 . 'Z';
    }

    $dt->set_time_zone('local');

    if ( first { $format eq $_ } qw(iso iso8601) ) {
        return join ' ', $dt->ymd('-'), $dt->hms(':'), $dt->strftime('%z');
    } elsif ( first { $format eq $_ } qw(rfc rfc2822) ) {
        $dt->set_locale('en_US');
        ( my $rv = $dt->strftime('%a, %d %b %Y %H:%M:%S %z') ) =~
            s/\+0000$/-0000/;
        return $rv;
    } else {
        if ($^O eq 'MSWin32') {
            require Win32::Locale;
            $dt->set_locale( Win32::Locale::get_locale() );
        } else {
            require POSIX;
            $dt->set_locale( POSIX::setlocale( POSIX::LC_TIME() ) );
        }
        return $dt->format_cldr($format) if $format =~ s/^cldr://;
        return $dt->strftime($format) if $format =~ s/^strftime://;
        my $meth = $dt->locale->can("datetime_format_$format") or hurl(
            datetime => __x(
                'Unknown date format "{format}"',
                format => $format
            )
        );
        return $dt->format_cldr( $dt->locale->$meth );
    }
}

1;

__END__

=head1 Name

App::Sqitch::DateTime - Sqitch DateTime object

=head1 Synopsis

  my $dt = App::Sqitch::DateTime->new(%params);
  say $dt->as_string( format => 'iso' );

=head1 Description

This subclass of L<DateTime> provides additional interfaces to support named
formats. These can be used for L<status|sqitch-status> or L<log|sqitch-log>
C<--date-format> options. App::Sqitch::DateTime provides a list of supported
formats, validates that a format string, and uses the formats to convert
itself into the appropriate string.

=head1 Interface

=head2 Class Methods

=head3 C<as_string_formats>

  my @formats = App::Sqitch::DateTime->as_string_formats;

Returns a list of formats supported by the C<format> parameter to
C<as_string>. The list currently includes:

=over

=item C<iso>

=item C<iso8601>

ISO-8601 format.

=item C<rfc>

=item C<rfc2822>

RFC-2822 format.

=item C<full>

=item C<long>

=item C<medium>

=item C<short>

Localized format of the specified length.

=item C<raw>

Show timestamps in raw format, which is strict ISO-8601 in the UTC time zone.

=item C<strftime:$string>

Show timestamps using an arbitrary C<strftime> pattern. See
L<DateTime/strftime Paterns> for comprehensive documentation of supported
patterns.

=item C<cldr:$string>

Show timestamps using an arbitrary C<cldr> pattern. See L<DateTime/CLDR
Paterns> for comprehensive documentation of supported patterns.

=back

=head3 C<validate_as_string_format>

  App::Sqitch::DateTime->validate_as_string_format($format);

Validates that a format is supported by C<as_string>. Throws an exception if
it's not, and returns if it is.

=head2 Instance Methods

=head3 C<as_string>

  $dt->as_string;
  $dt->as_string( format => $format );

Returns a string representation using the provided format. The format must be
one of those listed by C<as_string_formats> or an exception will be thrown. If
no format is passed, the string will be formatted with the C<raw> format.

=head1 See Also

=over

=item L<sqitch-status>

Documentation for the C<status> command to the Sqitch command-line client.

=item L<sqitch-log>

Documentation for the C<log> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2018 iovation Inc.

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
