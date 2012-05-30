package App::Sqitch::Command::deploy;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Moose;
require App::Sqitch::Plan;
use List::Util qw(first);
use namespace::autoclean;
extends 'App::Sqitch::Command';

our $VERSION = '0.32';

has to => (
    is  => 'ro',
    isa => 'Str',
);

sub options {
    return qw(
        to=s
    );
}

sub execute {
    my ( $self, $to ) = @_;
    my $sqitch = $self->sqitch;
    my $engine = $sqitch->engine;
    my $plan   = App::Sqitch::Plan->new( sqitch => $sqitch );

    $to = $self->to if defined $self->to;
    my $curr_tag = $engine->current_tag_name;
    my $to_index = $plan->count - 1;

    if (defined $to) {
        $to_index = $plan->index_of($to) // $sqitch->fail(
            qq{Unknown deploy target: "$to"}
        );

        if ($curr_tag) {
            # Make sure that $to is later than the current point.
            $plan->seek($curr_tag);
            $sqitch->fail(
                'Cannot deploy to an earlier target; use "revert" instead'
            ) if $to_index < $plan->position;

            # Just return if there is nothing to do.
            if ($to_index == $plan->position) {
                $sqitch->info("Nothing to deploy (already at $to)");
                return $self;
            }
        } else {
            # Initialize the database, if necessary.
            $engine->initialize unless $engine->initialized;
        }

    } elsif ($curr_tag) {
        # Skip to the current tag.
        $plan->seek($curr_tag);

        if ($plan->position == $to_index) {
            # We are up-to-date.
            $sqitch->info('Nothing to deploy (up-to-date)');
            return $self;
        }

    } else {
        # Initialize the database, if necessary.
        $engine->initialize unless $engine->initialized;
    }

    # Deploy!
    while ($plan->position < $to_index) {
        my $target = $plan->next;
        $sqitch->info('  + ', $target->format_name);
        if ($target->isa('App::Sqitch::Plan::Step')) {
            $engine->deploy($target);
        } elsif ($target->isa('App::Sqitch::Plan::Tag')) {
            $engine->apply($target);
        } else {
            # This should not happen.
            $sqitch->fail(
                'Cannot deploy node of type ', ref $target,
                '; can only deploy steps and apply tags'
            );
        }
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::deploy - Deploy Sqitch changes

=head1 Synopsis

  my $cmd = App::Sqitch::Command::deploy->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<deploy> command, you probably want to be
reading C<sqitch-deploy>. But if you really want to know how the C<deploy> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::deploy->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<deploy> command.

=head2 Instance Methods

=head3 C<execute>

  $deploy->execute;

Executes the deploy command.

=head1 See Also

=over

=item L<sqitch-deploy>

Documentation for the C<deploy> command to the Sqitch command-line client.

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
