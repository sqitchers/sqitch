package App::Sqitch::CommandOptions::deploy_variables;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use Mouse::Role;
use App::Sqitch::X qw(hurl);
requires 'configure';
use Mouse::Util::TypeConstraints;

has deploy_variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return {
            %{ $self->sqitch->config->get_section( section => 'deploy.variables' ) },
        };
    },
);

before 'configure' => sub {
    my ( $class, $config, $opt, $params ) = @_;
    if ( my $vars = $opt->{set} ) {
        $params->{deploy_variables} = {
            %{ $config->get_section( section => 'deploy.variables' ) },
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
};

1;
