package App::Sqitch::Command::log;

use 5.010;
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
use Try::Tiny;
use Term::ANSIColor 2.02 qw(color colorvalid);
extends 'App::Sqitch::Command';
use constant CAN_OUTPUT_COLOR => $^O eq 'MSWin32'
    ? try { require Win32::Console::ANSI }
    : -t *STDOUT;

BEGIN {
    $ENV{ANSI_COLORS_DISABLED} = 1 unless CAN_OUTPUT_COLOR;
}

our $VERSION = '0.938';

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

has event => (
    is      => 'ro',
    isa     => 'ArrayRef',
);

has change_pattern => (
    is      => 'ro',
    isa     => 'Str',
);

has project_pattern => (
    is      => 'ro',
    isa     => 'Str',
);

has committer_pattern => (
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
    isa     => 'Str',
    default => sub {
        shift->sqitch->config->get( key => 'log.date_format' ) || 'iso'
    }
);

has color => (
    is       => 'ro',
    isa      => enum([ qw(always never auto) ]),
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'log.color' ) || 'auto';
    },
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
                            hurl log => __ 'No label passed to the _ format';
                        }
                        default {
                            hurl log => __x(
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
                    hurl log => __x(
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
                    return __ 'Requires: ' . ' ' . join(
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
                    return __ 'Conflicts:' . ' ' . join(
                        $_[1] || ', ' => @{ $_[0]->{conflicts} }
                    ) . "\n";
                },
                a => sub {
                    hurl log => __x(
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

sub options {
    return qw(
        event=s@
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
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    # Make sure the date format is valid.
    if (my $format = $opt->{date_format}
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

    # Turn colors on or off as appropriate.
    $opt->{color} = 'never' if delete $opt->{no_color};
    if ( my $color = $opt->{color} || $config->get(key => 'log.color') ) {
        if ($color eq 'always') {
            delete $ENV{ANSI_COLORS_DISABLED};
        } elsif ($color eq 'never') {
            $ENV{ANSI_COLORS_DISABLED} = 1;
        } else {
            # Die on an invalid value.
            hurl log => __ 'Option "color" expects "always", "auto", or "never"'
                if $color ne 'auto';
            # For auto we do nothing.
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
        event     => $self->event,
        change    => $self->change_pattern,
        project   => $self->project_pattern,
        committer => $self->committer_pattern,
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
    $self->page( __x 'On database {db}', db => $engine->destination );
    while ( my $change = $iter->() ) {
        $self->page( $changef->format( $format, $change ) );
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
