package App::Sqitch::Command::log;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use App::Sqitch::DateTime;
use Moose;
use Moose::Util::TypeConstraints;
use String::Formatter;
use namespace::autoclean;
use Term::ANSIColor qw(color colorvalid);
extends 'App::Sqitch::Command';

our $VERSION = '0.61';

my %FORMATS;
$FORMATS{raw} = <<EOF;
event    %e
change   %h%T
name     %c
date     %{iso}d
agent    %a
EOF

$FORMATS{full} = <<EOF;
%{yellow}C%{change}_ %h%{reset}C%T
%{event}_ %e
%{name}_ %c
%{date}_ %d
%{by}_ %a
EOF

$FORMATS{long} = <<EOF;
%{yellow}C%L %h%{reset}C%T
%{name}_ %c
%{date}_ %d
%{by}_ %a
EOF

$FORMATS{medium} = <<EOF;
%{yellow}C%L %h%{reset}C%T
%{name}_ %c
%{date}_ %d
EOF

$FORMATS{short} = <<EOF;
%{yellow}C%h%{reset}C
%{short}d - %l %c - %a
EOF

$FORMATS{oneline} = '%h %l %c';

has change_pattern => (
    is      => 'ro',
    isa     => 'Str',
);

has actor_pattern => (
    is      => 'ro',
    isa     => 'Str',
);

has max_count => (
    is      => 'ro',
    isa     => 'Int',
);

has skip => (
    is      => 'ro',
    isa     => 'Int',
);

has reverse => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has abbrev => (
    is      => 'ro',
    isa     => 'Int',
    default => 0,
);

has format => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => $FORMATS{medium},
);

has date_format => (
    is      => 'ro',
    lazy    => 1,
    isa     => enum([ App::Sqitch::DateTime->as_string_formats ]),
    default => sub {
        shift->sqitch->config->get( key => 'log.date_format' ) || 'iso'
    }
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
                        __ 'Deploy' when 'deploy';
                        __ 'Revert' when 'revert';
                        __ 'Fail'   when 'fail';
                    };
                },
                l => sub {
                    given ($_[0]->{event}) {
                        __ 'deploy' when 'deploy';
                        __ 'revert' when 'revert';
                        __ 'fail'   when 'fail';
                    };
                },
                _ => sub {
                    hurl log => __ 'No label passed to the _ format'
                        unless $_[1];
                    given ($_[1]) {
                        __ 'Event: ' when 'event';
                        __ 'Change:' when 'change';
                        __ 'Actor: ' when 'actor';
                        __ 'By:    ' when 'by';
                        __ 'Date:  ' when 'date';
                        __ 'Name:  ' when 'name';
                        hurl log => __ 'No label passed to the _ format'
                            when undef;
                    };
                },
                H => sub { $_[0]->{change_id} },
                h => sub {
                    if (my $abb = $_[1] || $self->abbrev) {
                        return substr $_[0]->{change_id}, 0, $abb;
                    }
                    return $_[0]->{change_id};
                },
                i => sub {
                    $self->abbrev
                        ? substr $_[0]->{change_id}, 0, $self->abbrev
                        : $_[0]->{change_id};
                },
                c => sub { $_[0]->{change} },
                a => sub { $_[0]->{logged_by} },
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
                n => sub { "\n" },
                d => sub { shift->{logged_at}->as_string(format => shift || $self->date_format) },
                C => sub {
                    hurl log => __ '{color} is not a valid ANSI color', color => $_[1]
                        unless $_[1] && colorvalid $_[1];
                    color $_[1];
                },
            },
        });
    }
);

sub options {
    return qw(
        change-pattern|change|c=s
        actor-pattern|actor|a=s
        max-count|n=i
        skip=i
        reverse!
        abbrev=i
        format|f=s
        date-format|date=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    # Make sure the date format is valid.
    if (my $format = $opt->{'date-format'}
        || $config->get(key => 'log.date_format')
    ) {
        App::Sqitch::DateTime->validate_as_string_format($format);
    }

    # Make sure the log format is valid.
    if (my $format = $opt->{format}
        || $config->get(key => 'log.format')
    ) {
        if ($format =~ s/^format://) {
            $opt->{format} = $format;
        } else {
            $opt->{format} = $FORMATS{$format} or hurl log => __x(
                'Unknown log format "{format}"',
                format => $format
            );
        }
    }

    return $class->SUPER::configure( $config, $opt );
}

sub execute {
    my $self   = shift;
    my $engine = $self->engine;

    # Exit with status 1 on uninitialized database, probably not expected.
    hurl {
        ident   => 'log',
        exitval => 1,
        message => __x(
            'Database {db} has not been initilized for Sqitch',
            db => $engine->destination,
        ),
    } unless $engine->initialized;

    # Exit with status 1 on no events, probably not expected.
    my $iter = $engine->search_events(limit => 1);
    hurl {
        ident   => 'log',
        exitval => 1,
        message => __x(
            'No events logged to {db}',
            db => $engine->destination,
        ),
    } unless $iter->();

    # Search the event log.
    $iter = $engine->search_events(
        change    => $self->change_pattern,
        actor     => $self->actor_pattern,
        limit     => $self->max_count,
        offset    => $self->skip,
        direction => $self->reverse ? 'ASC' : 'DESC',
    );

    # Send the results.
    my $changef = $self->formatter;
    my $format  = $self->format;
    local $SIG{__DIE__} = sub {
        die @_ if $_[0] !~ /^Unknown conversion in stringf: (\S+)/;
        hurl log => __x 'Unknown log format code "{code}"', code => $1;
    };
    while ( my $change = $iter->() ) {
        $self->emit( $changef->format( $format, $change ) );
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::log - Show a database event log

=head1 Synopsis

  my $cmd = App::Sqitch::Command::log->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<log> command, you probably want to be
reading C<sqitch-log>. But if you really want to know how the C<log> command
works, read on.

=head1 Interface

=head2 Instance Methods

=head3 C<execute>

  $log->execute;

Executes the log command. The current state of the database will be compared
to the plan in order to show where things stand.

=head3 C<format_short>

  $log->format_short( $iterator );

Emits all of the events returned by the iterator in short format.

=head3 C<format_full>

  $log->format_full( $iterator );

Emits all of the events returned by the iterator in full format.

=head3 C<format_oneline>

  $log->format_oneline( $iterator );

Emits each event returned by the iterator as a single line.

=head3 C<format_table>

  $log->format_table( $iterator );

Emits all of the events returned by the iterator in table format.

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
