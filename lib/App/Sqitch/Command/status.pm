package App::Sqitch::Command::status;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Moose;
use Moose::Util::TypeConstraints;
extends 'App::Sqitch::Command';

our $VERSION = '0.52';

has show_changes => (
    is      => 'ro',
    isa     => 'Bool',
    lazy    => 1,
    default => sub {
        shift->sqitch->config->get(
            key => "status.show_changes",
            as  => 'bool',
        ) // 0;
    }
);

has show_tags => (
    is      => 'ro',
    isa     => 'Bool',
    lazy    => 1,
    default => sub {
        shift->sqitch->config->get(
            key => "status.show_tags",
            as  => 'bool',
        ) // 0;
    }
);

has date_format => (
    is      => 'ro',
    lazy    => 1,
    isa     => enum([qw(
        full
        long
        medium
        short
        iso
        iso8601
        rfc
        rfc2822
    )]),
    default => sub {
        shift->sqitch->config->get( key => 'status.date_format' ) || 'iso'
    }
);

sub options {
    return qw(
        show-tags
        show-changes
        date-format|date=s
    );
}

sub execute {
    my $self = shift;
    my $engine = $self->engine;

    $self->comment('On database ', $engine->destination);

    my $state = $engine->initialized ? $engine->current_state : undef;

    # Exit with status 1 on no state, probably not expected.
    hurl {
        ident   => 'status',
        message => __ 'No changes deployed',
        exitval => 1,
    } unless defined $state;

    # Emit the state basics.
    $self->emit_state($state);

    # Emit changes and tags, if required.
    $self->emit_changes;
    $self->emit_tags;

    # Emit the overall status.
    $self->emit_status($state);

    return $self;
}

sub emit_state {
    my ( $self, $state ) = @_;
    $self->comment(__x 'Change:   {change_id}', change_id => $state->{change_id});
    $self->comment(__x 'Name:     {change}',    change    => $state->{change});
    if (my @tags = @{ $state->{tags}} ) {
        $self->comment(__nx(
            'Tag:      {tags}',
            'Tags:     {tags}',
            @tags,
            tags => join(__ ', ', @tags),
        ));
    }

    $self->comment(__x(
        'Deployed: {date}',
        date => $self->_format_date( $state->{deployed_at} ),
    ));
    $self->comment(__x 'By:       {name}', name => $state->{deployed_by});
    return $self;
}

sub emit_changes {
    my $self = shift;
    return $self unless $self->show_changes;
}

sub emit_tags {
    my $self = shift;
    return $self unless $self->show_tags;
}

sub emit_status {
    my ( $self, $state ) = @_;
    my $plan = $self->plan;
    $self->comment('');

    my $idx = $plan->index_of( $state->{change_id} ) // do {
        # Whoops, cannot find this change in the plan.
        $self->vent(__x(
            'Cannot find this change in {file}',
            file => $self->sqitch->plan_file
        ));
        hurl status => __ 'Make sure you are connected to the proper database for this project.';
    };

    # Say something about our current state.
    if ($idx == $plan->count - 1) {
        $self->emit(__ 'Nothing to deploy (up-to-date)');
    } else {
        $self->emit(__n(
            'Undeployed change:',
            'Undeployed changes:',
            $plan->count - ($idx + 1)
        ));
        $plan->position($idx);
        while (my $change = $plan->next) {
            $self->emit('  * ', $change->format_name_with_tags);
        }
    }
    return $self;
}

sub _format_date {
    my ( $self, $dt ) = @_;
    my $format = $self->date_format;
    $dt->set_time_zone('local');

    if ($format ~~ [qw(iso iso8601)]) {
        return join ' ', $dt->ymd('-'), $dt->hms(':'), $dt->strftime('%z')
    } elsif ($format ~~ [qw(rfc rfc2822)]) {
        $dt->set( locale => 'en_US' );
        ( my $rv = $dt->strftime('%a, %d %b %Y %H:%M:%S %z') ) =~ s/\+0000$/-0000/;
        return $rv;
    } else {
        require POSIX;
        $dt->set(locale => POSIX::setlocale(POSIX::LC_TIME()) );
        my $meth = "datetime_format_$format";
        return $dt->format_cldr( $dt->locale->$meth );
    }
}

1;

__END__

=head1 Name

App::Sqitch::Command::status - Display status information about Sqitch

=head1 Synopsis

  my $cmd = App::Sqitch::Command::status->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<status> command, you probably want to be
reading C<sqitch-status>. But if you really want to know how the C<status> command
works, read on.

=head1 Interface

=head2 Instance Methods

=head3 C<execute>

  $status->execute;

Executes the status command. The current state of the database will be compared
to the plan in order to show where things stand.

=head3 C<emit_changes>

  $status->emit_changes;

Emits a list of deployed changes if C<show_changes> is true.

=head3 C<emit_tags>

  $status->emit_tags;

Emits a list of deployed tags if C<show_tags> is true.

=head3 C<emit_state>

  $status->emit_state($state);

Emits the current state of the database. Pass in a state hash as returned by
L<App::Sqitch::Engine> C<current_state()>.

=head3 C<emit_status>

  $status->emit_state($state);

Emits information about the current status of the database compared to the
plan. Pass in a state hash as returned by L<App::Sqitch::Engine>
C<current_state()>. Throws an exception if the current state's change cannot
be found in the plan.

=head1 See Also

=over

=item L<sqitch-status>

Documentation for the C<status> command to the Sqitch command-line client.

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
