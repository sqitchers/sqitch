package App::Sqitch::Command::plan;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Mouse;
use Mouse::Util::TypeConstraints;
use App::Sqitch::ItemFormatter;
use namespace::autoclean;
use Try::Tiny;
extends 'App::Sqitch::Command';

our $VERSION = '0.983';

my %FORMATS;
$FORMATS{raw} = <<EOF;
%{:event}C%e %H%{reset}C%T
name      %n
project   %o
%{requires}a%{conflicts}aplanner   %{name}p <%{email}p>
planned   %{date:raw}p

%{    }B
EOF

$FORMATS{full} = <<EOF;
%{:event}C%L %h%{reset}C%T
%{name}_ %n
%{project}_ %o
%R%X%{planner}_ %p
%{planned}_ %{date}p

%{    }B
EOF

$FORMATS{long} = <<EOF;
%{:event}C%L %h%{reset}C%T
%{name}_ %n
%{project}_ %o
%{planner}_ %p

%{    }B
EOF

$FORMATS{medium} = <<EOF;
%{:event}C%L %h%{reset}C
%{name}_ %n
%{planner}_ %p
%{date}_ %{date}p

%{    }B
EOF

$FORMATS{short} = <<EOF;
%{:event}C%L %h%{reset}C
%{name}_ %n
%{planner}_ %p

%{    }s
EOF

$FORMATS{oneline} = '%{:event}C%h %l%{reset}C %n%{cyan}C%t%{reset}C';

has event => (
    is      => 'ro',
    isa     => 'Str',
);

has change_pattern => (
    is      => 'ro',
    isa     => 'Str',
);

has planner_pattern => (
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

has format => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => $FORMATS{medium},
);

has formatter => (
    is       => 'ro',
    isa      => 'App::Sqitch::ItemFormatter',
    required => 1,
    lazy     => 1,
    default  => sub { App::Sqitch::ItemFormatter->new },
);

sub options {
    return qw(
        event=s
        change-pattern|change=s
        planner-pattern|planner=s
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
        key => 'plan.date_format'
    );
    if ($date_format) {
        App::Sqitch::DateTime->validate_as_string_format($date_format);
    } else {
        $date_format = 'iso';
    }

    # Make sure the plan format is valid.
    if (my $format = $opt->{format}
        || $config->get(key => 'plan.format')
    ) {
        if ($format =~ s/^format://) {
            $opt->{format} = $format;
        } else {
            $opt->{format} = $FORMATS{$format} or hurl plan => __x(
                'Unknown plan format "{format}"',
                format => $format
            );
        }
    }

    # Determine how to handle ANSI colors.
    my $color = delete $opt->{no_color} ? 'never'
        : delete $opt->{color} || $config->get(key => 'plan.color');

    $opt->{formatter} = App::Sqitch::ItemFormatter->new(
        ( $date_format   ? ( date_format => $date_format          ) : () ),
        ( $color         ? ( color       => $color                ) : () ),
        ( $opt->{abbrev} ? ( abbrev      => delete $opt->{abbrev} ) : () ),
    );

    return $class->SUPER::configure( $config, $opt );
}

sub execute {
    my $self   = shift;
    my $plan = $self->plan;

    # Exit with status 1 on no changes, probably not expected.
    hurl {
        ident   => 'plan',
        exitval => 1,
        message => __x(
            'No changes in {file}',
            file => $self->sqitch->plan_file,
        ),
    } unless $plan->count;

    # Search the changes.
    my $iter = $plan->search_changes(
        operation => $self->event,
        name      => $self->change_pattern,
        planner   => $self->planner_pattern,
        limit     => $self->max_count,
        offset    => $self->skip,
        direction => $self->reverse ? 'DESC' : 'ASC',
    );

    # Send the results.
    my $formatter = $self->formatter;
    my $format    = $self->format;
    $self->page( '# ', __x 'Project: {project}', project => $plan->project );
    $self->page( '# ', __x 'File:    {file}', file => $self->sqitch->plan_file );
    $self->page('');
    while ( my $change = $iter->() ) {
        $self->page( $formatter->format( $format, {
            event         => $change->is_deploy ? 'deploy' : 'revert',
            project       => $change->project,
            change_id     => $change->id,
            change        => $change->name,
            note          => $change->note,
            tags          => [ map { $_->format_name } $change->tags ],
            requires      => [ map { $_->as_string } $change->requires ],
            conflicts     => [ map { $_->as_string } $change->conflicts ],
            planned_at    => $change->timestamp,
            planner_name  => $change->planner_name,
            planner_email => $change->planner_email,
        } ) );
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::plan - List the changes in the plan

=head1 Synopsis

  my $cmd = App::Sqitch::Command::plan->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<plan> command, you probably want to be
reading C<sqitch-plan>. But if you really want to know how the C<plan> command
works, read on.

=head1 Interface

=head2 Instance Methods

=head3 C<execute>

  $plan->execute;

Executes the plan command. The plan will be searched and the results output.

=head1 See Also

=over

=item L<sqitch-plan>

Documentation for the C<plan> command to the Sqitch command-line client.

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
