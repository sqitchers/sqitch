package App::Sqitch::Command::check;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use Types::Standard qw(Str HashRef);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ContextCommand';
with 'App::Sqitch::Role::ConnectingCommand';

# VERSION

has target => (
    is  => 'ro',
    isa => Str,
);

has from_change => (
    is  => 'ro',
    isa => Str,
);

has to_change => (
    is  => 'ro',
    isa => Str,
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
        from-change|from=s
        to-change|to=s
        set|s=s%
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = map {
        $_ => $opt->{$_}
    } grep {
        exists $opt->{$_}
    } qw(target from_change to_change);

    if ( my $vars = $opt->{set} ) {
        $params{variables} = $vars;
    }

    return \%params;
}

sub _collect_vars {
    my ($self, $target) = @_;
    my $cfg = $self->sqitch->config;
    return (
        %{ $cfg->get_section(section => 'core.variables') },
        %{ $cfg->get_section(section => 'deploy.variables') },
        %{ $cfg->get_section(section => 'check.variables') },
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
    my $from = $self->from_change // shift @{ $changes };
    my $to   = $self->to_change   // shift @{ $changes };
    $self->warn(__x(
        'Too many changes specified; checking from "{from}" to "{to}"',
        from => $from,
        to   => $to,
    )) if @{ $changes };

    # Now get to work.
    my $engine = $target->engine;
    $engine->set_variables( $self->_collect_vars($target) );
    $engine->check($from, $to);
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::check - Runs various checks and prints a report

=head1 Synopsis

  my $cmd = App::Sqitch::Command::check->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<check> command, you probably want to be
reading C<sqitch-check>. But if you really want to know how the C<check> command
works, read on.

=head1 Interface

=head2 Attributes

=head3 C<target_name>

The name or URI of the database target as specified by the C<--target> option.

=head3 C<target>

An L<App::Sqitch::Target> object from which to perform the checks. Must be
instantiated by C<execute()>.

=head2 Instance Methods

=head3 C<execute>

  $check->execute;

Executes the check command. The current state of the target database will be
compared to the plan in order to show where things stand.

=head1 See Also

=over

=item L<sqitch-check>

Documentation for the C<check> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>
Matthieu Foucault <matthieu@button.is>

=head1 License

Copyright (c) 2012-2021 iovation Inc., Button Inc.

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
