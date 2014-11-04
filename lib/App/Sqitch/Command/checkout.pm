package App::Sqitch::Command::checkout;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(Str);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use App::Sqitch::Plan;
use Path::Class qw(dir);
use Try::Tiny;
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::RevertDeployCommand';

our $VERSION = '0.998';

has client => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        return $sqitch->config->get( key => 'core.vcs.client' )
            || 'git' . ( $^O eq 'MSWin32' ? '.exe' : '' );
    },
);

sub configure { {} }

sub execute {
    my $self = shift;
    my %args = $self->parse_args(target => $self->target, args => \@_);

    # The branch arg will be the one parse_args does not recognize.
    my $branch = shift @{ $args{unknown} } // $self->usage;

    # Die on unknowns.
    if (my @unknown = ( @{ $args{unknown} }, @{ $args{changes} } ) ) {
        hurl checkout => __nx(
            'Unknown argument "{arg}"',
            'Unknown arguments: {arg}',
            scalar @unknown,
            arg => join ', ', @unknown
        );
    }

    # Warn on multiple targets.
    my $target = shift @{ $args{targets} };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target->name,
    )) if @{ $args{targets} };


    # Now get to work.
    my $sqitch = $self->sqitch;
    my $git    = $self->client;
    my $engine = $target->engine;
    $engine->with_verify( $self->verify );
    $engine->no_prompt( $self->no_prompt );
    $engine->prompt_accept( $self->prompt_accept );
    $engine->log_only( $self->log_only );

    # What branch are we on?
    my $current_branch = $sqitch->probe($git, qw(rev-parse --abbrev-ref HEAD));
    hurl {
        ident   => 'checkout',
        message => __x('Already on branch {branch}', branch => $branch),
        exitval => 1,
    } if $current_branch eq $branch;

    # Instantitate a plan without calling $target->plan.
    my $from_plan = App::Sqitch::Plan->new(
        sqitch => $sqitch,
        target => $target,
    );

    # Load the branch plan from Git, assuming the same path.
    my $to_plan = App::Sqitch::Plan->new(
        sqitch => $sqitch,
        target => $target,
      )->parse(
        # XXX Handle missing file/no contents.
        scalar $sqitch->capture( $git, 'show', "$branch:" . $target->plan_file)
    );

    # Find the last change the plans have in common.
    my $last_common_change;
    for my $change ($to_plan->changes){
        last unless $from_plan->get( $change->id );
        $last_common_change = $change;
    }

    hurl checkout => __x(
        'Branch {branch} has no changes in common with current branch {current}',
        branch  => $branch,
        current => $current_branch,
    ) unless $last_common_change;

    $sqitch->info(__x(
        'Last change before the branches diverged: {last_change}',
        last_change => $last_common_change->format_name_with_tags,
    ));

    # Revert to the last common change.
    if (my %v = %{ $self->revert_variables }) { $engine->set_variables(%v) }
    $engine->plan( $from_plan );
    try {
        $engine->revert( $last_common_change->id );
    } catch {
        # Rethrow unknown errors or errors with exitval > 1.
        die $_ if ! eval { $_->isa('App::Sqitch::X') }
            || $_->exitval > 1
            || $_->ident eq 'revert:confirm';
        # Emite notice of non-fatal errors (e.g., nothign to revert).
        $self->info($_->message)
    };


    # Check out the new branch.
    $sqitch->run($git, 'checkout', $branch);

    # Deploy!
    if (my %v = %{ $self->deploy_variables}) { $engine->set_variables(%v) }
    $engine->plan( $to_plan );
    $engine->deploy( undef, $self->mode);
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::checkout - Revert, change checkout a VCS branch, and redeploy

=head1 Synopsis

  my $cmd = App::Sqitch::Command::checkout->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<checkout> command, you probably want to
be reading C<sqitch-checkout>. But if you really want to know how the
C<checkout> command works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::checkout->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<checkout> command.

=head2 Instance Methods

=head3 C<execute>

  $checkout->execute;

Executes the checkout command.

=head1 See Also

=over

=item L<sqitch-checkout>

Documentation for the C<checkout> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Authors

=over

=item * Ronan Dunklau <ronan@dunklau.fr>

=item * David E. Wheeler <david@justatheory.com>

=back

=head1 License

Copyright (c) 2012-2014 Ronan Dunklau & iovation Inc.

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
