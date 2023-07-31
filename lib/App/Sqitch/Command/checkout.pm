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

# VERSION

has client => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        return $sqitch->config->get( key => 'core.vcs.client' )
            || 'git' . ( App::Sqitch::ISWIN ? '.exe' : '' );
    },
);

sub configure { {} }

sub execute {
    my $self = shift;
    my ($branch, $targets) = $self->parse_args(
        target     => $self->target,
        names      => [undef],
        args       => \@_,
        no_changes => 1,
    );

    # Branch required.
    $self->usage unless length $branch;

    # Warn on multiple targets.
    my $target = shift @{ $targets };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target->name,
    )) if @{ $targets };

    # Now get to work.
    my $sqitch = $self->sqitch;
    my $git    = $self->client;
    my $engine = $target->engine;
    $engine->with_verify( $self->verify );
    $engine->log_only( $self->log_only );
    $engine->lock_timeout( $self->lock_timeout );

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
        # Git assumes a relative file name is relative to the repo root, even
        # when you're in a subdirectory. So we have to prepend the currrent
        # directory path ./ to convince it to read the file relative to the
        # current directory. See #560 and
        # https://git-scm.com/docs/gitrevisions#Documentation/gitrevisions.txt-emltrevgtltpathgtemegemHEADREADMEememmasterREADMEem
        # for details.
        # XXX Handle missing file/no contents.
        scalar $sqitch->capture(
            $git, 'show', "$branch:"
            . File::Spec->catfile(File::Spec->curdir, $target->plan_file)
        )
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
    $engine->set_variables( $self->_collect_revert_vars($target) );
    $engine->plan( $from_plan );
    try {
        $engine->revert( $last_common_change->id, ! $self->no_prompt, $self->prompt_accept );
    } catch {
        # Rethrow unknown errors or errors with exitval > 1.
        die $_ if ! eval { $_->isa('App::Sqitch::X') }
            || $_->exitval > 1
            || $_->ident eq 'revert:confirm';
        # Emite notice of non-fatal errors (e.g., nothing to revert).
        $self->info($_->message)
    };


    # Check out the new branch.
    $sqitch->run($git, 'checkout', $branch);

    # Deploy!
    $engine->set_variables( $self->_collect_deploy_vars($target) );
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

Copyright (c) 2012-2023 iovation Inc., David E. Wheeler

Copyright (c) 2012-2013 Ronan Dunklau

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
