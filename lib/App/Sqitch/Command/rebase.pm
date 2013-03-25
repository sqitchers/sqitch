package App::Sqitch::Command::rebase;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse;
use Mouse::Util::TypeConstraints;
use List::Util qw(first);
use Hash::Merge 'merge';
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::RevertDeployCommand';

our $VERSION = '0.954';

has onto_target => (
    is  => 'ro',
    isa => 'Str',
);

has upto_target => (
    is  => 'ro',
    isa => 'Str',
);

sub options {
    return qw(
        onto-target|onto=s
        upto-target|upto=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    return { map { $_ => $opt->{$_} } grep { exists $opt->{$_} } qw(
        onto_target
        upto_target
    ) };
}

sub execute {
    my $self   = shift;
    my $engine = $self->sqitch->engine;
    $engine->with_verify( $self->verify );
    $engine->no_prompt( $self->no_prompt );
    if (my %v = %{ $self->revert_variables }) { $engine->set_variables(%v) }
    $engine->revert( $self->onto_target // shift, $self->log_only );
    if (my %v = %{ $self->deploy_variables }) { $engine->set_variables(%v) }
    $engine->deploy( $self->upto_target // shift, $self->mode, $self->log_only );
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
