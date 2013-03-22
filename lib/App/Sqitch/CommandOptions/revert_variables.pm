package App::Sqitch::CommandOptions::revert_variables;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse::Role;
use Mouse::Util::TypeConstraints;

requires 'sqitch';
requires 'configure';
requires 'deploy_variables';

has revert_variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return {
            %{ $self->deploy_variables },
            %{ $self->sqitch->config->get_section( section => 'revert.variables' ) },
        };
    },
);

before 'configure' => sub {
    my ( $class, $config, $opt, $params) = @_;
    if ( my $vars = $opt->{set} ) {
        $params->{revert_variables} = {
            %{ $opt->{set_deploy} || {} },
            %{ $config->get_section( section => 'deploy.variables' ) },
            %{ $config->get_section( section => 'revert.variables' ) },
            %{ $vars }
        };
    }

    if ( my $vars = $opt->{set_revert} ) {
        $params->{revert_variables} = {
            %{
                $params->{revert_variables}
                || $config->get_section( section => 'deploy.variables' )
            },
            %{
                $params->{revert_variables}
                || $config->get_section( section => 'revert.variables' )
            },
            %{ $vars },
        };
    }
};

1;
