package App::Sqitch::Command::revert;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use Types::Standard qw(Str Bool HashRef);
use List::Util qw(first);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ContextCommand';
with 'App::Sqitch::Role::ConnectingCommand';

# VERSION

has target => (
    is  => 'ro',
    isa => Str,
);

has to_change => (
    is  => 'ro',
    isa => Str,
);

has modified => (
    is      => 'ro',
    isa     => Bool,
    default => 0,
);

has no_prompt => (
    is  => 'ro',
    isa => Bool
);

has prompt_accept => (
    is  => 'ro',
    isa => Bool
);

has log_only => (
    is       => 'ro',
    isa      => Bool,
    default  => 0,
);

has variables => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub { {} },
);

sub options {
    return qw(
        target|t=s
        to-change|to|change=s
        set|s=s%
        log-only
        modified|m
        y
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = map { $_ => $opt->{$_} } grep { exists $opt->{$_} } qw(
        to_change
        log_only
        target
        modified
    );

    if ( my $vars = $opt->{set} ) {
        $params{variables} = $vars
    }

    $params{no_prompt} = delete $opt->{y} // $config->get(
        key => 'revert.no_prompt',
        as  => 'bool',
    ) // 0;

    $params{prompt_accept} = $config->get(
        key => 'revert.prompt_accept',
        as  => 'bool',
    ) // 1;

    return \%params;
}

sub _collect_vars {
    my ($self, $target) = @_;
    my $cfg = $self->sqitch->config;
    return (
        %{ $cfg->get_section(section => 'core.variables') },
        %{ $cfg->get_section(section => 'deploy.variables') },
        %{ $cfg->get_section(section => 'revert.variables') },
        %{ $target->variables }, # includes engine
        %{ $self->variables },   # --set
    );
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
    my $engine = $target->engine;
    my $change = $self->modified
        ? $engine->planned_deployed_common_ancestor_id
        : $self->to_change // shift @{ $changes };
    $self->warn(__x(
        'Too many changes specified; reverting to "{change}"',
        change => $change,
    )) if @{ $changes };

    # Now get to work.
    $engine->no_prompt( $self->no_prompt );
    $engine->prompt_accept( $self->prompt_accept );
    $engine->log_only( $self->log_only );
    $engine->set_variables( $self->_collect_vars($target) );
    $engine->revert( $change );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::revert - Revert Sqitch changes from a database

=head1 Synopsis

  my $cmd = App::Sqitch::Command::revert->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<revert> command, you probably want to be
reading C<sqitch-revert>. But if you really want to know how the C<revert> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::revert->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<revert> command.

=head2 Attributes

=head3 C<log_only>

Boolean indicating whether to log the deploy without running the scripts.

=head3 C<no_prompt>

Boolean indicating whether or not to prompt the user to really go through with
the revert.

=head3 C<prompt_accept>

Boolean value to indicate whether or not the default value for the prompt,
should the user hit C<return>, is to accept the prompt or deny it.

=head3 C<target>

The deployment target URI.

=head3 C<to_change>

Change to revert to.

=head2 Instance Methods

=head3 C<execute>

  $revert->execute;

Executes the revert command.

=head1 See Also

=over

=item L<sqitch-revert>

Documentation for the C<revert> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2018 iovation Inc.

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
