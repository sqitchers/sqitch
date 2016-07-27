package App::Sqitch::Command::log;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Moo;
use Types::Standard qw(Str Int ArrayRef Bool);
use Type::Utils qw(class_type);
use App::Sqitch::ItemFormatter;
use namespace::autoclean;
use Try::Tiny;
extends 'App::Sqitch::Command';

our $VERSION = '0.9996';

my %FORMATS;
$FORMATS{raw} = <<EOF;
%{:event}C%e %H%{reset}C%T
name      %n
project   %o
%{requires}a%{conflicts}aplanner   %{name}p <%{email}p>
planned   %{date:raw}p
committer %{name}c <%{email}c>
committed %{date:raw}c

%{    }B
EOF

$FORMATS{full} = <<EOF;
%{:event}C%L %h%{reset}C%T
%{name}_ %n
%{project}_ %o
%R%X%{planner}_ %p
%{planned}_ %{date}p
%{committer}_ %c
%{committed}_ %{date}c

%{    }B
EOF

$FORMATS{long} = <<EOF;
%{:event}C%L %h%{reset}C%T
%{name}_ %n
%{project}_ %o
%{planner}_ %p
%{committer}_ %c

%{    }B
EOF

$FORMATS{medium} = <<EOF;
%{:event}C%L %h%{reset}C
%{name}_ %n
%{committer}_ %c
%{date}_ %{date}c

%{    }B
EOF

$FORMATS{short} = <<EOF;
%{:event}C%L %h%{reset}C
%{name}_ %n
%{committer}_ %c

%{    }s
EOF

$FORMATS{oneline} = '%{:event}C%h %l%{reset}C %o:%n %s';

has target => (
    is  => 'ro',
    isa => Str,
);

has event => (
    is      => 'ro',
    isa     => ArrayRef,
);

has change_pattern => (
    is      => 'ro',
    isa     => Str,
);

has project_pattern => (
    is      => 'ro',
    isa     => Str,
);

has committer_pattern => (
    is      => 'ro',
    isa     => Str,
);

has max_count => (
    is      => 'ro',
    isa     => Int,
);

has skip => (
    is      => 'ro',
    isa     => Int,
);

has reverse => (
    is      => 'ro',
    isa     => Bool,
    default => 0,
);

has format => (
    is       => 'ro',
    isa      => Str,
    default  => $FORMATS{medium},
);

has formatter => (
    is       => 'ro',
    isa      => class_type('App::Sqitch::ItemFormatter'),
    lazy     => 1,
    default  => sub { App::Sqitch::ItemFormatter->new },
);

sub options {
    return qw(
        event=s@
        target|t=s
        change-pattern|change=s
        project-pattern|project=s
        committer-pattern|committer=s
        format|f=s
        date-format|date=s
        max-count|n=i
        skip=i
        reverse!
        color=s
        no-color
        abbrev=i
        oneline
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    # Set base values if --oneline.
    if ($opt->{oneline}) {
        $opt->{format} ||= 'oneline';
        $opt->{abbrev} //= 6;
    }

    # Determine and validate the date format.
    my $date_format = delete $opt->{date_format} || $config->get(
        key => 'log.date_format'
    );
    if ($date_format) {
        require App::Sqitch::DateTime;
        App::Sqitch::DateTime->validate_as_string_format($date_format);
    } else {
        $date_format = 'iso';
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

    # Determine how to handle ANSI colors.
    my $color = delete $opt->{no_color} ? 'never'
        : delete $opt->{color} || $config->get(key => 'log.color');

    $opt->{formatter} = App::Sqitch::ItemFormatter->new(
        ( $date_format   ? ( date_format => $date_format          ) : () ),
        ( $color         ? ( color       => $color                ) : () ),
        ( $opt->{abbrev} ? ( abbrev      => delete $opt->{abbrev} ) : () ),
    );

    return $class->SUPER::configure( $config, $opt );
}

sub execute {
    my ( $self, $target ) = @_;

    if (my $t = $self->target // $target) {
        $self->warn(__x(
            'Both the --target option and the target argument passed; using {option}',
            option => $self->target,
        )) if $target && $self->target;
        require App::Sqitch::Target;
        $target = App::Sqitch::Target->new(sqitch => $self->sqitch, name => $t);
    } else {
        $target = $self->default_target;
    }
    my $engine = $target->engine;

    # Exit with status 1 on uninitialized database, probably not expected.
    hurl {
        ident   => 'log',
        exitval => 1,
        message => __x(
            'Database {db} has not been initialized for Sqitch',
            db => $engine->registry_destination,
        ),
    } unless $engine->initialized;

    # Exit with status 1 on no events, probably not expected.
    my $iter = $engine->search_events(limit => 1);
    hurl {
        ident   => 'log',
        exitval => 1,
        message => __x(
            'No events logged for {db}',
            db => $engine->destination,
        ),
    } unless $iter->();

    # Search the event log.
    $iter = $engine->search_events(
        event     => $self->event,
        change    => $self->change_pattern,
        project   => $self->project_pattern,
        committer => $self->committer_pattern,
        limit     => $self->max_count,
        offset    => $self->skip,
        direction => $self->reverse ? 'ASC' : 'DESC',
    );

    # Send the results.
    my $formatter = $self->formatter;
    my $format    = $self->format;
    $self->page( __x 'On database {db}', db => $engine->destination );
    while ( my $change = $iter->() ) {
        $self->page( $formatter->format( $format, $change ) );
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

=head2 Attributes

=head3 C<change_pattern>

Regular expression to match against change names.

=head3 C<committer_pattern>

Regular expression to match against committer names.

=head3 C<project_pattern>

Regular expression to match against project names.

=head3 C<event>

Event type buy which to filter entries to display.

=head3 C<format>

Display format template.

=head3 C<max_count>

Maximum number of entries to display.

=head3 C<reverse>

Reverse the usual order of the display of entries.

=head3 C<skip>

Number of entries to skip before displaying entries.

=head3 C<target>

The database target from which to read the log.

=head2 Instance Methods

=head3 C<execute>

  $log->execute;

Executes the log command. The current log for the target database will be
searched and the resulting change history displayed.

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
