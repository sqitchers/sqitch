package App::Sqitch::Command::checkout;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse;
use Mouse::Util::TypeConstraints;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use App::Sqitch::Plan;
use Git::Wrapper;
use FileHandle;

extends 'App::Sqitch::Command';

our $VERSION = '0.953';


has deploy_variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'deploy.variables' );
    },
);

has verify => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has log_only => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);


has revert_variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'deploy.variables' );
    },
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


sub options {
    return qw(
        mode=s
        set|s=s%
        set-deploy|d=s%
        set-revert|r=s%
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
    if ( my $vars = $opt->{set} ) {
        # Merge with config.
        $params{deploy_variables} = {
            %{ $config->get_section( section => 'deploy.variables' ) },
            %{ $vars },
        };
        $params{revert_variables} = {
            %{ $params{deploy_variables} },
            %{ $config->get_section( section => 'revert.variables' ) },
            %{ $vars },
        };
    }
    if ( my $vars = $opt->{set_deploy} ) {
        $params{deploy_variables} = {
            %{
                $params{deploy_variables}
                || $config->get_section( section => 'deploy.variables' )
            },
            %{ $vars },
        };
    }
    if ( my $vars = $opt->{set_revert} ) {
        $params{revert_variables} = {
            %{
                $params{deploy_variables}
                || $config->get_section( section => 'deploy.variables' )
            },
            %{
                $params{revert_variables}
                || $config->get_section( section => 'revert.variables' )
            },
            %{ $vars },
        };
    }
    return \%params;
}

sub execute {
    my ( $self, $branch) = @_;
    $self->usage unless defined $branch;
    my $sqitch = $self->sqitch;
    my $plan = $sqitch->plan;
    my $engine = $sqitch->engine;
    $engine->with_verify( $self->verify );
    my $git = Git::Wrapper->new('.');
    my @current_branch = $git->rev_parse("--abbrev-ref", "HEAD");
    hurl plan => __x(
        'Already on branch {branch}',
        branch=>$branch) if $current_branch[0] eq $branch;
    my $other_content = join("\n", $git->show($branch . ':' .
            $sqitch->plan_file));
    my $fh;
    open($fh, '<', \$other_content) or die;
    my $old_plan = App::Sqitch::Plan->new(
        sqitch => $sqitch,
        plan_file => $fh);
    $old_plan->load;
    my $last_common_change;
    foreach($old_plan->changes){
        if(!$plan->get($_->id)){
            last;
        } else {
            $last_common_change = $_;
        }
    }
    $sqitch->info(__x(
        'Last change before the branches diverged: {last_change}',
        last_change=> $last_common_change->format_name_with_tags,
    ));
    if (my %v = %{ $self->revert_variables }) {
        $engine->set_variables(%v)
    }
    $engine->revert( $last_common_change->id, $self->log_only );
    if(not $self->log_only){
        $git->checkout($branch);
    }
    $sqitch->plan = $old_plan;
    if (my %v = %{ $self->deploy_variables}) { $engine->set_variables(%v) }
    $engine->deploy( undef, $self->mode, $self->log_only);
    return $self;
}

1;
