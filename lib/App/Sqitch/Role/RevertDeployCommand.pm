package App::Sqitch::Role::RevertDeployCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use App::Sqitch::Types qw(Str Bool HashRef);
use Type::Utils qw(enum);
use namespace::autoclean;

requires 'sqitch';
requires 'command';
requires 'options';
requires 'configure';

our $VERSION = '0.996';

has target => (
    is  => 'ro',
    isa => Str,
);

has verify => (
    is       => 'ro',
    isa      => Bool,
    default  => 0,
);

has log_only => (
    is       => 'ro',
    isa      => Bool,
    default  => 0,
);

has no_prompt => (
    is  => 'ro',
    isa => Bool
);

has prompt_accept => (
    is  => 'ro',
    isa => Bool
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

has deploy_variables => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return {
            %{ $self->sqitch->config->get_section( section => 'deploy.variables' ) },
        };
    },
);

has revert_variables => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return {
            %{ $self->deploy_variables },
            %{ $self->sqitch->config->get_section( section => 'revert.variables' ) },
        };
    },
);

around options => sub {
    my ($orig, $class) = @_;
    return ($class->$orig), qw(
        target|t=s
        mode=s
        verify!
        set|s=s%
        set-deploy|d=s%
        set-revert|r=s%
        log-only
        y
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;
    my $cmd = $class->command;

    my $params = $class->$orig($config, $opt);
    $params->{log_only} = $opt->{log_only} if $opt->{log_only};
    $params->{target}   = $opt->{target}   if $opt->{target};

    # Verify?
    $params->{verify} = $opt->{verify}
                     // $config->get( key => "$cmd.verify", as => 'boolean' )
                     // $config->get( key => 'deploy.verify', as => 'boolean' )
                     // 0;
    $params->{mode} = $opt->{mode}
                   || $config->get( key => "$cmd.mode" )
                   || $config->get( key => 'deploy.mode' )
                   || 'all';

    if ( my $vars = $opt->{set} ) {
        # Merge with config.
        $params->{deploy_variables} = {
            %{ $config->get_section( section => 'deploy.variables' ) },
            %{ $vars },
        };
        $params->{revert_variables} = {
            %{ $params->{deploy_variables} },
            %{ $config->get_section( section => 'revert.variables' ) },
            %{ $vars },
        };
    }

    if ( my $vars = $opt->{set_deploy} ) {
        $params->{deploy_variables} = {
            %{
                $params->{deploy_variables}
                || $config->get_section( section => 'deploy.variables' )
            },
            %{ $vars },
        };
    }

    if ( my $vars = $opt->{set_revert} ) {
        $params->{revert_variables} = {
            %{
                $params->{deploy_variables}
                || $config->get_section( section => 'deploy.variables' )
            },
            %{
                $params->{revert_variables}
                || $config->get_section( section => 'revert.variables' )
            },
            %{ $vars },
        };
    }

    $params->{no_prompt} = delete $opt->{y} // $config->get(
        key => "$cmd.no_prompt",
        as  => 'bool',
    ) // $config->get(
        key => 'revert.no_prompt',
        as  => 'bool',
    ) // 0;

    $params->{prompt_accept} = $config->get(
        key => "$cmd.prompt_accept",
        as  => 'bool',
    ) // $config->get(
        key => 'revert.prompt_accept',
        as  => 'bool',
    ) // 1;

    return $params;
};

1;

__END__

=head1 Name

App::Sqitch::Role::RevertDeployCommand - A command that reverts and deploys

=head1 Synopsis

  package App::Sqitch::Command::rebase;
  extends 'App::Sqitch::Command';
  with 'App::Sqitch::Role::RevertDeployCommand';

=head1 Description

This role encapsulates the common attributes and methods required by commands
that both revert and deploy.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::checkout->options;

Adds options common to the commands that revert and deploy.

=head3 C<configure>

Configures the options common to commands that revert and deploy.

=head1 See Also

=over

=item L<App::Sqitch::Command::rebase>

The C<rebase> command reverts and deploys changes.

=item L<App::Sqitch::Command::checkout>

The C<checkout> command takes a VCS commit name, determines the last change in
common with the current commit, reverts to that change, then checks out the
named commit and re-deploys.

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
