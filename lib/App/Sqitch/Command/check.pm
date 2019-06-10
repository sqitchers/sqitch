package App::Sqitch::Command::check;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Moo;
use App::Sqitch::Types qw(Str Target Engine Change);
use Try::Tiny;
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ContextCommand';
with 'App::Sqitch::Role::ConnectingCommand';

# VERSION

has target_name => (
    is  => 'ro',
    isa => Str,
);

has target => (
    is      => 'rw',
    isa     => Target,
    handles => [qw(engine plan plan_file)],
);

has date_format => (
    is      => 'ro',
    lazy    => 1,
    isa     => Str,
    default => sub {
        shift->sqitch->config->get( key => 'status.date_format' ) || 'iso'
    }
);

has project => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { $self->plan->project } catch {
            # Just die on parse and I/O errors.
            die $_ if try { $_->ident eq 'parse' || $_->ident eq 'io' };

            # Try to extract a project name from the registry.
            my $engine = $self->engine;
            hurl status => __ 'Database not initialized for Sqitch'
                unless $engine->initialized;
            my @projs = $engine->registered_projects
                or hurl status => __ 'No projects registered';
            hurl status => __x(
                'Use --project to select which project to query: {projects}',
                projects => join __ ', ', @projs,
            ) if @projs > 1;
            return $projs[0];
        };
    },
);

sub options {
    return qw(
        project=s
        target|t=s
    );
}

sub execute {
    my $self = shift;
    my ($targets) = $self->parse_args(
        target => $self->target_name,
        args   => \@_,
    );

    # Warn on multiple targets.
    my $target = shift @{ $targets };
    $self->warn(__x(
        'Too many targets specified; connecting to {target}',
        target => $target->name,
    )) if @{ $targets };

    # Good to go.
    $self->target($target);
    my $engine = $target->engine;

    # Where are we?
    $self->comment( __x 'On database {db}', db => $engine->destination );

    # Exit with status 1 on no state, probably not expected.
    my $state = try {
        $engine->current_state( $self->project )
    } catch {
        # Just die on parse and I/O errors.
        die $_ if try { $_->ident eq 'parse' || $_->ident eq 'io' };

        # Hrm. Maybe not initialized?
        die $_ if $engine->initialized;
        hurl status => __x(
            'Database {db} has not been initialized for Sqitch',
            db => $engine->registry_destination
        );
    };

    my @deployed_changes = $engine->deployed_changes;

    my %deployed_script_hashes;
    foreach my $change ($engine->deployed_changes) {
        $deployed_script_hashes{$change->{'id'}} = $change->{'script_hash'};
    }

    my $workdir_plan = $target->plan;
    my @workdir_changes = $workdir_plan->changes;
    foreach my $change (@workdir_changes) {
        $self->comment(__x(
            'Working directory script {script_file} is different from deployed script',
            script_file => $change->deploy_file
        )) if $change->script_hash ne $deployed_script_hashes{$change->id};
    }

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
