package App::Sqitch::ItemFormatter;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use App::Sqitch::DateTime;
use Mouse;
use Mouse::Util::TypeConstraints;
use String::Formatter;
use namespace::autoclean;
use Try::Tiny;
use Term::ANSIColor 2.02 qw(color colorvalid);

use constant CAN_OUTPUT_COLOR => $^O eq 'MSWin32'
    ? try { require Win32::Console::ANSI }
    : -t *STDOUT;

BEGIN {
    $ENV{ANSI_COLORS_DISABLED} = 1 unless CAN_OUTPUT_COLOR;
}

our $VERSION = '0.971';

has abbrev => (
    is      => 'ro',
    isa     => 'Int',
    default => 0,
);

has date_format => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => 'iso',
);

has color => (
    is       => 'ro',
    isa      => enum([ qw(always never auto) ]),
    required => 1,
    default  => 'auto',
);

has formatter => (
    is      => 'ro',
    lazy    => 1,
    isa     => 'String::Formatter',
    default => sub {
        my $self = shift;
        String::Formatter->new({
            input_processor => 'require_single_input',
            string_replacer => 'method_replace',
            codes => {
                e => sub { $_[0]->{event} },
                L => sub {
                    given ($_[0]->{event}) {
                        when ('deploy') { return __ 'Deploy' }
                        when ('revert') { return __ 'Revert' }
                        when ('fail')   { return __ 'Fail'   }
                    }
                },
                l => sub {
                    given ($_[0]->{event}) {
                        when ('deploy') { return __ 'deploy' }
                        when ('revert') { return __ 'revert' }
                        when ('fail')   { return __ 'fail'   }
                    }
                },
                _ => sub {
                    given ($_[1]) {
                        when ('event')     { return __ 'Event:    ' }
                        when ('change')    { return __ 'Change:   ' }
                        when ('committer') { return __ 'Committer:' }
                        when ('planner')   { return __ 'Planner:  ' }
                        when ('by')        { return __ 'By:       ' }
                        when ('date')      { return __ 'Date:     ' }
                        when ('committed') { return __ 'Committed:' }
                        when ('planned')   { return __ 'Planned:  ' }
                        when ('name')      { return __ 'Name:     ' }
                        when ('project')   { return __ 'Project:  ' }
                        when ('email')     { return __ 'Email:    ' }
                        when ('requires')  { return __ 'Requires: ' }
                        when ('conflicts') { return __ 'Conflicts:' }
                        when (undef)       {
                            hurl format => __ 'No label passed to the _ format';
                        }
                        default {
                            hurl format => __x(
                                'Unknown label "{label}" passed to the _ format',
                                label => $_[1],
                            );
                        }
                    };
                },
                H => sub { $_[0]->{change_id} },
                h => sub {
                    if (my $abb = $_[1] || $self->abbrev) {
                        return substr $_[0]->{change_id}, 0, $abb;
                    }
                    return $_[0]->{change_id};
                },
                n => sub { $_[0]->{change} },
                o => sub { $_[0]->{project} },

                c => sub {
                    return "$_[0]->{committer_name} <$_[0]->{committer_email}>"
                        unless defined $_[1];
                    return $_[0]->{committer_name}  if $_[1] ~~ [qw(n name)];
                    return $_[0]->{committer_email} if $_[1] ~~ [qw(e email)];
                    return $_[0]->{committed_at}->as_string(
                        format => $_[1] || $self->date_format
                    ) if $_[1] =~ s/^d(?:ate)?(?::|$)//;
                },

                p => sub {
                    return "$_[0]->{planner_name} <$_[0]->{planner_email}>"
                        unless defined $_[1];
                    return $_[0]->{planner_name}  if $_[1] ~~ [qw(n name)];
                    return $_[0]->{planner_email} if $_[1] ~~ [qw(e email)];
                    return $_[0]->{planned_at}->as_string(
                        format => $_[1] || $self->date_format
                    ) if $_[1] =~ s/^d(?:ate)?(?::|$)//;
                },

                t => sub {
                    @{ $_[0]->{tags} }
                        ? ' ' . join $_[1] || ', ' => @{ $_[0]->{tags} }
                        : '';
                },
                T => sub {
                    @{ $_[0]->{tags} }
                        ? ' (' . join($_[1] || ', ' => @{ $_[0]->{tags} }) . ')'
                        : '';
                },
                v => sub { "\n" },
                C => sub {
                    if (($_[1] // '') eq ':event') {
                        # Select a color based on some attribute.
                        return color $_[0]->{event} eq 'deploy' ? 'green'
                                   : $_[0]->{event} eq 'revert' ? 'blue'
                                   : 'red';
                    }
                    hurl format => __x(
                        '{color} is not a valid ANSI color', color => $_[1]
                    ) unless $_[1] && colorvalid $_[1];
                    color $_[1];
                },
                s => sub {
                    ( my $s = $_[0]->{note} ) =~ s/\v.*//ms;
                    return ($_[1] // '') . $s;
                },
                b => sub {
                    return '' unless $_[0]->{note} =~ /\v/;
                    ( my $b = $_[0]->{note} ) =~ s/^.+\v+//;
                    $b =~ s/^/$_[1]/gms if defined $_[1] && length $b;
                    return $b;
                },
                B => sub {
                    return $_[0]->{note} unless defined $_[1];
                    ( my $note = $_[0]->{note} ) =~ s/^/$_[1]/gms;
                    return $note;
                },
                r => sub {
                    @{ $_[0]->{requires} }
                        ? ' ' . join $_[1] || ', ' => @{ $_[0]->{requires} }
                        : '';
                },
                R => sub {
                    return '' unless @{ $_[0]->{requires} };
                    return __ ('Requires: ') . ' ' . join(
                        $_[1] || ', ' => @{ $_[0]->{requires} }
                    ) . "\n";
                },
                x => sub {
                    @{ $_[0]->{conflicts} }
                        ? ' ' . join $_[1] || ', ' => @{ $_[0]->{conflicts} }
                        : '';
                },
                X => sub {
                    return '' unless @{ $_[0]->{conflicts} };
                    return __('Conflicts:') . ' ' . join(
                        $_[1] || ', ' => @{ $_[0]->{conflicts} }
                    ) . "\n";
                },
                a => sub {
                    hurl format => __x(
                        '{attr} is not a valid change attribute', attr => $_[1]
                    ) unless $_[1] && exists $_[0]->{ $_[1] };
                    my $val = $_[0]->{ $_[1] } // return '';

                    if (ref $val eq 'ARRAY') {
                        return '' unless @{ $val };
                        $val = join ', ' => @{ $val };
                    } elsif (eval { $val->isa('App::Sqitch::DateTime') }) {
                        $val = $val->as_string( format => 'raw' );
                    }

                    my $sp = ' ' x (9 - length $_[1]);
                    return "$_[1]$sp $val\n";
                }
            },
        });
    }
);

sub format {
    my $self = shift;
    local $SIG{__DIE__} = sub {
        die @_ if $_[0] !~ /^Unknown conversion in stringf: (\S+)/;
        hurl format => __x 'Unknown format code "{code}"', code => $1;
    };

    # Older versions of TERM::ANSIColor check for definedness.
    local $ENV{ANSI_COLORS_DISABLED} = $self->color eq 'always' ? undef
        :                              $self->color eq 'never'  ? 1
        :                              $ENV{ANSI_COLORS_DISABLED};

    return $self->formatter->format(@_);
}

1;

__END__

=head1 Name

App::Sqitch::ItemFormatter - Format events and changes for command output

=head1 Synopsis

  my $formatter = App::Sqitch::ItemFormatter->new(%params);
  say $formatter->format($format, $item);

=head1 Description

This class is used by commands to format items for output. For example,
L<C<log>|sqitch-log> uses it to format the events it finds. It uses
L<String::Formatter> to do the actual formatting, but configures it for all
the various times of things typically displayed, such as change names, IDs,
event types, etc. This keeps things relatively simple, as all one needs to
pass to C<format()> is a format and then a hash reference of values to be used
in the format.

=head1 Interface

=head2 Constructor

=head3 C<new>

  my $formatter = App::Sqitch::ItemFormatter->new(%params);

Constructs and returns a formatter object. The supported parameters are:

=over

=item C<abbrev>

Instead of showing the full 40-byte hexadecimal change ID, format as a partial
prefix the specified number of characters long.

=item C<date_format>

Format to use for timestamps. Defaults to C<iso>. Allowed values:

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

A format length to pass to the system locale's C<LC_TIME> category.

=item C<raw>

Raw format, which is strict ISO-8601 in the UTC time zone.

=item C<strftime:$string>

An arbitrary C<strftime> pattern. See L<DateTime/strftime Paterns> for
comprehensive documentation of supported patterns.

=item C<cldr:$pattern>

An arbitrary C<cldr> pattern. See L<DateTime/CLDR Paterns> for comprehensive
documentation of supported patterns.

=back

=item C<color>

Controls the use of ANSI color formatting. The value may be one of:

=over

=item C<auto> (the default)

=item C<always>

=item C<never>

=back

=item C<formatter>

A String::Formatter object. You probably don't want to pass one of these, as
the default one understands all the values to that Sqitch is likely to want to
format.

=back

=head2 Instance Methods

=head3 C<format>

  $formatter->format( $format, $item );

Formats an item as a string and returns it. The item will be formatted using
the first argument. See L</Formats> for the gory details.

The second argument is a hash reference defining the item to be formatted.
These are simple key/value pairs, generally identifying attribute names and
values. The supported keys are:

=over

=item C<event>

The type of event, which is one of:

=over

=item C<deploy>

=item C<revert>

=item C<fail>

=back

=item C<project>

The name of the project with which the change is associated.

=item C<change_id>

The change ID.

=item C<change>

The name of the change.

=item C<note>

A brief description of the change.

=item C<tags>

An array reference of the names of associated tags.

=item C<requires>

An array reference of the names of any changes required by the change.

=item C<conflicts>

An array reference of the names of any changes that conflict with the change.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
event was logged.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head1 Formats

The format argument to C<format()> specifies the item information to be
included in the resulting string. It works a little bit like C<printf> format
and a little like Git log format. For example, this format:

  format:The committer of %h was %{name}c%vThe title was >>%s<<%v

Would show something like this:

  The committer of f26a3s was Tom Lane
  The title was >>We really need to get this right.<<

The placeholders are:

=over

=item * C<%H>: Event change ID

=item * C<%h>: Event change ID (respects C<--abbrev>)

=item * C<%n>: Event change name

=item * C<%o>: Event change project name

=item * C<%($len)h>: abbreviated change of length C<$len>

=item * C<%e>: Event type (deploy, revert, fail)

=item * C<%l>: Localized lowercase event type label

=item * C<%L>: Localized title case event type label

=item * C<%c>: Event committer name and email address

=item * C<%{name}c>: Event committer name

=item * C<%{email}c>: Event committer email address

=item * C<%{date}c>: commit date (respects C<--date-format>)

=item * C<%{date:rfc}c>: commit date, RFC2822 format

=item * C<%{date:iso}c>: commit date, ISO-8601 format

=item * C<%{date:full}c>: commit date, full format

=item * C<%{date:long}c>: commit date, long format

=item * C<%{date:medium}c>: commit date, medium format

=item * C<%{date:short}c>: commit date, short format

=item * C<%{date:cldr:$pattern}c>: commit date, formatted with custom L<CLDR pattern|DateTime/CLDR Patterns>

=item * C<%{date:strftime:$pattern}c>: commit date, formatted with custom L<strftime pattern|DateTime/strftime Patterns>

=item * C<%c>: Change planner name and email address

=item * C<%{name}p>: Change planner name

=item * C<%{email}p>: Change planner email address

=item * C<%{date}p>: plan date (respects C<--date-format>)

=item * C<%{date:rfc}p>: plan date, RFC2822 format

=item * C<%{date:iso}p>: plan date, ISO-8601 format

=item * C<%{date:full}p>: plan date, full format

=item * C<%{date:long}p>: plan date, long format

=item * C<%{date:medium}p>: plan date, medium format

=item * C<%{date:short}p>: plan date, short format

=item * C<%{date:cldr:$pattern}p>: plan date, formatted with custom L<CLDR pattern|DateTime/CLDR Patterns>

=item * C<%{date:strftime:$pattern}p>: plan date, formatted with custom L<strftime pattern|DateTime/strftime Patterns>

=item * C<%t>: Comma-delimited list of tags

=item * C<%{$sep}t>: list of tags delimited by C<$sep>

=item * C<%T>: Parenthesized list of comma-delimited tags

=item * C<%{$sep}T>: Parenthesized list of tags delimited by C<$sep>

=item * C<%s>: Subject (a.k.a. title line)

=item * C<%r>: Comma-delimited list of required changes

=item * C<%{$sep}r>: list of required changes delimited by C<$sep>

=item * C<%R>: Localized label and list of comma-delimited required changes

=item * C<%{$sep}R>: Localized label and list of required changes delimited by C<$sep>

=item * C<%x>: Comma-delimited list of conflicting changes

=item * C<%{$sep}x>: list of conflicting changes delimited by C<$sep>

=item * C<%X>: Localized label and list of comma-delimited conflicting changes

=item * C<%{$sep}X>: Localized label and list of conflicting changes delimited by C<$sep>

=item * C<%b>: Body

=item * C<%B>: Raw body (unwrapped subject and body)

=item * C<%{$prefix}>B: Raw body with C<$prefix> prefixed to every line

=item * C<%{event}_> Localized label for "event"

=item * C<%{change}_> Localized label for "change"

=item * C<%{committer}_> Localized label for "committer"

=item * C<%{planner}_> Localized label for "planner"

=item * C<%{by}_> Localized label for "by"

=item * C<%{date}_> Localized label for "date"

=item * C<%{committed}_> Localized label for "committed"

=item * C<%{planned}_> Localized label for "planned"

=item * C<%{name}_> Localized label for "name"

=item * C<%{project}_> Localized label for "project"

=item * C<%{email}_> Localized label for "email"

=item * C<%{requires}_> Localized label for "requires"

=item * C<%{conflicts}_> Localized label for "conflicts"

=item * C<%v> vertical space (newline)

=item * C<%{$color}C>: An ANSI color: black, red, green, yellow, reset, etc.

=item * C<%{:event}C>: An ANSI color based on event type (green deploy, blue revert, red fail)

=item * C<%{$attribute}a>: The raw attribute name and value, if it exists and has a value

=back

=head1 See Also

=over

=item L<sqitch-log>

Documentation for the C<log> command to the Sqitch command-line client.

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
