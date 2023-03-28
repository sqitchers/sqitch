package App::Sqitch::Role::RevertDeployCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use App::Sqitch::Types qw(Str Int Bool HashRef);
use Type::Utils qw(enum);
use namespace::autoclean;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);

requires 'sqitch';
requires 'command';
requires 'options';
requires 'configure';

with 'App::Sqitch::Role::ContextCommand';
with 'App::Sqitch::Role::ConnectingCommand';

# VERSION

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

has lock_timeout => (
    is      => 'ro',
    isa     => Int,
    lazy    => 1,
    default => sub { App::Sqitch::Engine::default_lock_timeout() },
);

has no_prompt => (
    is  => 'ro',
    isa => Bool
);

has prompt_accept => (
    is  => 'ro',
    isa => Bool
);

has strict => (
    is       => 'ro',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $cmd = $self->command;
        return ($self->sqitch->config->get(
                    key => "$cmd.strict",
                    as  => 'bool',
                ) // $self->sqitch->config->get(
                    key => 'revert.strict',
                    as  => 'bool',
                ) // 0);
    }
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
    default  => sub { {} },
);

has revert_variables => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub { {} },
);

sub _collect_deploy_vars {
    my ($self, $target) = @_;
    my $cfg = $self->sqitch->config;
    return (
        %{ $cfg->get_section(section => 'core.variables') },
        %{ $cfg->get_section(section => 'deploy.variables') },
        %{ $target->variables }, # includes engine
        %{ $self->deploy_variables }, # --set, --set-deploy
    );
}

sub _collect_revert_vars {
    my ($self, $target) = @_;
    my $cfg = $self->sqitch->config;
    return (
        %{ $cfg->get_section(section => 'core.variables') },
        %{ $cfg->get_section(section => 'deploy.variables') },
        %{ $cfg->get_section(section => 'revert.variables') },
        %{ $target->variables }, # includes engine
        %{ $self->revert_variables }, # --set, --set-revert
    );
}

around options => sub {
    my ($orig, $class) = @_;
    return ($class->$orig), qw(
        target|t=s
        mode=s
        verify!
        set|s=s%
        set-deploy|e=s%
        set-revert|r=s%
        log-only
        lock-timeout=i
        y
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;
    my $cmd = $class->command;

    my $params = $class->$orig($config, $opt);
    for my $key (qw(log_only target lock_timeout)) {
        $params->{$key} = $opt->{$key} if exists $opt->{$key};
    }

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
        # --set used for both revert and deploy.
        $params->{revert_variables} = $params->{deploy_variables} = $vars;
    }

    if ( my $vars = $opt->{set_deploy} ) {
        # --set-deploy used only for deploy.
        $params->{deploy_variables} = {
            %{ $params->{deploy_variables} || {} },
            %{ $vars },
        };
    }

    if ( my $vars = $opt->{set_revert} ) {
        # --set-revert used only for revert.
        $params->{revert_variables} = {
            %{ $params->{revert_variables} || {} },
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

sub BUILD {
    my ($self, $args) = @_;

    if ($self->strict) {
        hurl {
            ident   => 'lax_command',
            exitval => 1,
            message => __x(
                '"{command}" cannot be used when strict mode is enabled.\n'.
                'Consider using revert and deploy commands directly.',
                command => $self->command,
                ),
        };
    }
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

=head2 Attributes

=head3 C<log_only>

Boolean indicating whether to log the deploy without running the scripts.

=head3 C<lock_timeout>

The number of seconds to wait for an exclusive advisory lock on the target,
for engines that support the feature.

=head3 C<no_prompt>

Boolean indicating whether or not to prompt the user to really go through with
the revert.

=head3 C<prompt_accept>

Boolean value to indicate whether or not the default value for the prompt,
should the user hit C<return>, is to accept the prompt or deny it.

=head3 C<strict>

Boolean value to indicate whether or not strict mode is enabled; if
so, use of these commands is prohibited.

=head3 C<target>

The deployment target URI.

=head3 C<verify>

Boolean indicating whether or not to run verify scripts after deploying
changes.

=head3 C<mode>

Deploy mode, one of "change", "tag", or "all".

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

Copyright (c) 2012-2022 iovation Inc., David E. Wheeler

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
