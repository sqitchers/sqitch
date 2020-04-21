package App::Sqitch::Command::deploy;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(URI Str Bool HashRef);
use Locale::TextDomain qw(App-Sqitch);
use Type::Utils qw(enum);
use App::Sqitch::X qw(hurl);
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

has to_change => (
    is  => 'ro',
    isa => Str,
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
    isa      => Bool,
    default  => 0,
);

has verify => (
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
        mode=s
        set|s=s%
        log-only
        verify!
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
        %{ $target->variables }, # includes engine
        %{ $self->variables },   # --set
    );
}

sub execute {
    my $self = shift;
    my ($targets, $changes) = $self->parse_args(
        target     => $self->target,
        args       => \@_,
    );

    # Warn on multiple targets.
    my $target = shift @{ $targets };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target->name,
    )) if @{ $targets };

    # Warn on too many changes.
    my $change = $self->to_change // shift @{ $changes };
    $self->warn(__x(
        'Too many changes specified; deploying to "{change}"',
        change => $change,
    )) if @{ $changes };

    # Now get to work.
    my $engine = $target->engine;
    $engine->with_verify( $self->verify );
    $engine->log_only( $self->log_only );
    $engine->set_variables( $self->_collect_vars($target) );
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

=head2 Attributes

=head3 C<log_only>

Boolean indicating whether to log the deploy without running the scripts.

=head3 C<mode>

Deploy mode, one of "change", "tag", or "all".

=head3 C<target>

The deployment target URI.

=head3 C<to_change>

Change up to which to deploy.

=head3 C<verify>

Boolean indicating whether or not to run verify scripts after each change.

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
