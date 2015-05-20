package App::Sqitch::Command::rebase;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use Types::Standard qw(Str);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use List::Util qw(first);
use Try::Tiny;
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::RevertDeployCommand';

our $VERSION = '0.9993';

has onto_change => (
    is  => 'ro',
    isa => Str,
);

has upto_change => (
    is  => 'ro',
    isa => Str,
);

sub options {
    return qw(
        onto-change|onto=s
        upto-change|upto=s
        onto-target=s
        upto-target=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my $p = { map { $_ => $opt->{$_} } grep { exists $opt->{$_} } qw(
        onto_change
        upto_change
    ) };

    # Handle deprecated options.
    for my $key (qw(onto upto)) {
        if (my $val = $opt->{"$key\_target"}) {
            App::Sqitch->warn(__x(
                'Option --{old} has been deprecated; use --{new} instead',
                old => "$key-target",
                new => "$key-change",
            ));
            $p->{"$key\_change"} ||= $val;
        }
    }

    return $p;
}

sub execute {
    my $self = shift;
    my ($targets, $changes) = $self->parse_args(
        target => $self->target,
        args   => \@_,
    );

    # Warn on multiple targets.
    my $target = shift @{ $targets };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target->name,
    )) if @{ $targets };

    # Warn on too many changes.
    my $onto = $self->onto_change // shift @{ $changes };
    my $upto = $self->upto_change // shift @{ $changes };
    $self->warn(__x(
        'Too many changes specified; rebasing onto "{onto}" up to "{upto}"',
        onto => $onto,
        upto => $upto,
    )) if @{ $changes };


    # Now get to work.
    my $engine = $target->engine;
    $engine->with_verify( $self->verify );
    $engine->no_prompt( $self->no_prompt );
    $engine->prompt_accept( $self->prompt_accept );
    $engine->log_only( $self->log_only );

    # Revert.
    if (my %v = %{ $self->revert_variables }) { $engine->set_variables(%v) }
    try {
        $engine->revert( $onto );
    } catch {
        # Rethrow unknown errors or errors with exitval > 1.
        die $_ if ! eval { $_->isa('App::Sqitch::X') }
            || $_->exitval > 1
            || $_->ident eq 'revert:confirm';
        # Emit notice of non-fatal errors (e.g., nothign to revert).
        $self->info($_->message)
    };

    # Deploy.
    if (my %v = %{ $self->deploy_variables }) { $engine->set_variables(%v) }
    $engine->deploy( $upto, $self->mode );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::rebase - Revert and redeploy Sqitch changes

=head1 Synopsis

  my $cmd = App::Sqitch::Command::rebase->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<rebase> command, you probably want to be
reading C<sqitch-rebase>. But if you really want to know how the C<rebase> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::rebase->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<rebase> command.

=head2 Attributes

=head3 C<onto_change>

Change onto which to rebase the target.

=head3 C<upto_change>

Change up to which to rebase the target.

=head2 Instance Methods

=head3 C<execute>

  $rebase->execute;

Executes the rebase command.

=head1 See Also

=over

=item L<sqitch-rebase>

Documentation for the C<rebase> command to the Sqitch command-line client.

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
