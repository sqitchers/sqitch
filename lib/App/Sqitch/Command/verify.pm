package App::Sqitch::Command::verify;

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

our $VERSION = '0.9991';

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
    default  => sub {
        shift->sqitch->config->get_section( section => 'verify.variables' );
    },
);

sub options {
    return qw(
        target|t=s
        from-change|from=s
        to-change|to=s
        from-target=s
        to-target=s
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

    # Handle deprecated options.
    for my $key (qw(from to)) {
        if (my $val = $opt->{"$key\_target"}) {
            App::Sqitch->warn(__x(
                'Option --{old} has been deprecated; use --{new} instead',
                old => "$key-target",
                new => "$key-change",
            ));
            $params{"$key\_change"} ||= $val;
        }
    }

    if ( my $vars = $opt->{set} ) {
        # Merge with config.
        $params{variables} = {
            %{ $config->get_section( section => 'verify.variables' ) || {} },
            %{ $vars },
        };
    }

    return \%params;
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
        'Too many changes specified; verifying from "{from}" to "{to}"',
        from => $from,
        to   => $to,
    )) if @{ $changes };

    # Now get to work.
    my $engine = $target->engine;
    if (my %v = %{ $self->variables }) { $engine->set_variables(%v) }
    $engine->verify($from, $to);
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::verify - Verify deployed Sqitch changes

=head1 Synopsis

  my $cmd = App::Sqitch::Command::verify->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<verify> command, you probably want to be
reading C<sqitch-verify>. But if you really want to know how the C<verify> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::verify->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<verify> command.

=head2 Attributes

=head3 C<onto_change>

Change onto which to rebase the target.

=head3 C<target>

The verify target database URI.

=head3 C<from_change>

Change from which to verify changes.

=head3 C<to_change>

Change up to which to verify changes.

=head2 Instance Methods

=head3 C<execute>

  $verify->execute;

Executes the verify command.

=head1 See Also

=over

=item L<sqitch-verify>

Documentation for the C<verify> command to the Sqitch command-line client.

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
