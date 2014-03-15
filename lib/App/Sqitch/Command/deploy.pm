package App::Sqitch::Command::deploy;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse;
use Mouse::Util::TypeConstraints;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use List::Util qw(first);
use namespace::autoclean;
extends 'App::Sqitch::Command';

our $VERSION = '0.993';

has target => (
    is  => 'ro',
    isa => 'Str',
);

has to_change => (
    is  => 'ro',
    isa => 'Str',
);

has mode => (
    is  => 'ro',
    isa => enum([qw(
        change
        tag
        all
    )]),
    default => 'all',
);

has log_only => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has verify => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'deploy.variables' );
    },
);

sub options {
    return qw(
        target|t=s
        to-change|to|change=s
        mode=s
        set|s=s%
        log-only
        verify!
        to-target=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = (
        mode     => $opt->{mode}   || $config->get( key => 'deploy.mode' )   || 'all',
        verify   => $opt->{verify} // $config->get( key => 'deploy.verify', as => 'boolean' ) // 0,
        log_only => $opt->{log_only} || 0,
    );
    $params{to_change} = $opt->{to_change} if exists $opt->{to_change};
    $params{target}    = $opt->{target}    if exists $opt->{target};

    if ( exists $opt->{to_target} ) {
        # Deprecated option.
        App::Sqitch->warn(
            __ 'The --to-target and --target option has been deprecated; use --to-change instead.'
        );
        $params{to_change} ||= $opt->{to_target};
    }

    if ( my $vars = $opt->{set} ) {
        # Merge with config.
        $params{variables} = {
            %{ $config->get_section( section => 'deploy.variables' ) || {} },
            %{ $vars },
        };
    }

    return \%params;
}

sub execute {
    my $self = shift;
    my %args = $self->parse_args(@_);

    # Die on unknowns.
    if (my @unknown = @{ $args{unknown}} ) {
        hurl deploy => __nx(
            'Unknown argument "{arg}"',
            'Unknown arguments: {arg}',
            scalar @unknown,
            arg => join ', ', @unknown
        );
    }

    # Warn on multiple targets.
    my $target = $self->target // shift @{ $args{targets} };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target,
    )) if @{ $args{targets} };

    # Warn on too many changes.
    my $change = $self->to_change // shift @{ $args{changes} };
    $self->warn(__x(
        'Too many changes specified; deploying to "{change}"',
        change => $change,
    )) if @{ $args{changes} };

    # Now get to work.
    my $engine = $self->engine_for_target($target);
    $engine->with_verify( $self->verify );
    $engine->log_only( $self->log_only );
    if (my %v = %{ $self->variables }) { $engine->set_variables(%v) }
    $engine->deploy( $change, $self->mode );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::deploy - Deploy Sqitch changes to a database

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

Copyright (c) 2012-2014 iovation Inc.

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
