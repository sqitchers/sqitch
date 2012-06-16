package App::Sqitch::Engine;

use v5.10.1;
use Moose;
use utf8;
use Try::Tiny;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use namespace::autoclean;

our $VERSION = '0.32';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
    handles  => { destination => 'db_name' },
);

has start_at => (
    is  => 'rw',
    isa => 'Str'
);

sub load {
    my ( $class, $p ) = @_;

    # We should have a command.
    hurl 'Missing "engine" parameter to load()' unless $p->{engine};

    # Load the engine class.
    my $pkg = __PACKAGE__ . "::$p->{engine}";
    eval "require $pkg" or hurl "Unable to load $pkg";
    return $pkg->new( sqitch => $p->{sqitch} );
}

sub name {
    my $class = ref $_[0] || shift;
    return '' if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    return $class;
}

sub config_vars { return }

sub deploy {
    my ( $self, $to, $mode ) = @_;
    my $sqitch   = $self->sqitch;
    my $plan     = $self->_sync_plan;
    my $to_index = $plan->count - 1;

    hurl plan => __ 'Nothing to deploy (empty plan)' if $to_index < 0;

    if (defined $to) {
        $to_index = $plan->index_of($to) // hurl plan => __x(
            'Unknown deploy target: "{target}"',
            target => $to,
        );

        # Just return if there is nothing to do.
        if ($to_index == $plan->position) {
            $sqitch->info(__x(
                'Nothing to deploy (already at "{target}"',
                target => $to
            ));
            return $self;
        }
    }

    if ($plan->position == $to_index) {
        # We are up-to-date.
        $sqitch->info(__ 'Nothing to deploy (up-to-date)');
        return $self;

    } elsif ($plan->position == -1) {
        # Initialize the database, if necessary.
        $self->initialize unless $self->initialized;

    } else {
        # Make sure that $to_index is greater than the current point.
        hurl deploy => __ 'Cannot deploy to an earlier target; use "revert" instead'
            if $to_index < $plan->position;
    }

    $sqitch->info(
        defined $to ? __x(
            'Deploying to {destination} through {target}',
            destination => $self->destination,
            target      => $to
        ) : __x(
            'Deploying to {destination}',
            destination => $self->destination,
        )
    );

    $mode ||= 'all';
    my $meth = $mode eq 'step' ? '_deploy_by_step'
             : $mode eq 'tag'  ? '_deploy_by_tag'
             : $mode eq 'all'  ? '_deploy_all'
             : hurl deploy => __x 'Unknown deployment mode: "{mode}"', mode => $mode;
    ;

    $self->$meth($plan, $to_index);
}

sub revert {
    my ( $self, $to ) = @_;
    my $sqitch = $self->sqitch;
    my $plan   = $self->sqitch->plan;

    my @step_ids;

    if (defined $to) {
        my $step = $plan->get($to) // plan => __x(
            'Unknown revert target: "{target}"',
            target => $to,
        );

        @step_ids = $self->deployed_step_ids_since($step) or hurl engine => __x(
            'Target not deployed: "{target}"',
            target => $to,
        );

        $sqitch->info(__x(
            'Reverting from {destination} to {target}',
            destination => $self->destination,
            target      => $to
        ));
    } else {
        @step_ids = $self->deployed_step_ids or hurl engine => __(
            'Nothing to revert (nothing deployed)',
        );
        $sqitch->info(__x(
            'Reverting all changes from {destination}',
            destination => $self->destination,
        ));
    }

    # Get the list of steps to revert before we do actual work.
    my @steps = map { $plan->get($_) } reverse @step_ids;

    # Do we want to support modes, where failures would re-deploy to previous
    # tag or all the way back to the starting point? This would be very much
    # like deploy() mode. I'm thinking not, as a failure on a revert is not
    # something you generaly want to recover from by deploying back to where
    # you started. But maybe I'm wrong?
    $self->revert_step($_) for reverse @steps;

    return $self;
}

sub _deploy_by_step {
    my ( $self, $plan, $to_index ) = @_;

    # Just deploy each node. If any fails, we just stop.
    while ($plan->position < $to_index) {
        $self->deploy_step($plan->next);
    }

    return $self;
}

sub _rollback {
    my ($self, $tag) = (shift, shift);
    my $sqitch = $self->sqitch;

    if (my @run = reverse @_) {
        $tag = $tag ? $tag->format_name : $self->start_at;
        $sqitch->vent(
            $tag ? __x('Reverting to {target}', target => $tag)
                 : __ 'Reverting all changes'
        );

        try {
            $self->revert_step($_) for @run;
        } catch {
            # Sucks when this happens.
            $sqitch->vent(eval { $_->message } // $_);
            $sqitch->vent(__ 'The schema will need to be manually repaired');
        };
    }

    hurl deploy => __ 'Deploy failed';
}

sub _deploy_by_tag {
    my ( $self, $plan, $to_index ) = @_;

    my ($last_tag, @run);
    try {
        while ($plan->position < $to_index) {
            my $step = $plan->next;
            $self->deploy_step($step);
            push @run => $step;
            if ($step->tags) {
                @run = ();
                ($last_tag) = $step->tags
            }
        }
    } catch {
        $self->sqitch->vent(eval { $_->message } // $_);
        $self->_rollback($last_tag, @run);
    };

    return $self;
}

sub _deploy_all {
    my ( $self, $plan, $to_index ) = @_;

    my @run;
    try {
        while ($plan->position < $to_index) {
            my $step = $plan->next;
            $self->deploy_step($step);
            push @run => $step;
        }
    } catch {
        $self->sqitch->vent(eval { $_->message } // $_);
        $self->_rollback(undef, @run);
    };

    return $self;
}

sub _sync_plan {
    my $self = shift;
    my $plan = $self->sqitch->plan;

    if (my $id = $self->latest_step_id) {
        my $idx = $plan->index_of($id) // hurl plan => __x(
            'Cannot find {target} in the plan',
            target => $id
        );
        $plan->position($idx);
        $self->start_at( $plan->get($id)->format_name );
    } else {
        $plan->reset;
    }
    return $plan;
}

sub is_deployed {
    my ($self, $thing) = @_;
    return $thing->isa('App::Sqitch::Plan::Tag')
        ? $self->is_deployed_tag($thing)
        : $self->is_deployed_step($thing);
}

sub deploy_step {
    my ( $self, $step ) = @_;
    my $sqitch = $self->sqitch;
    $sqitch->info('  + ', $step->format_name);

    # Check for conflicts.
    if (my @conflicts = $self->check_conflicts($step)) {
        hurl deploy => __nx(
            'Conflicts with previously deployed step: {steps}',
            'Conflicts with previously deployed steps: {steps}',
            scalar @conflicts,
            steps => join ' ', @conflicts,
        )
    }

    # Check for prerequisites.
    if (my @required = $self->check_requires($step)) {
        hurl deploy => __nx(
            'Missing required step: {steps}',
            'Missing required steps: {steps}',
            scalar @required,
            steps => join ' ', @required,
        );
    }

    return try {
        # XXX Start a transaction and lock the steps table.
        $self->run_file($step->deploy_file);
        $self->log_deploy_step($step);
    } catch {
        $self->log_fail_step($step);
        die $_;
    };
}

sub revert_step {
    my ( $self, $step ) = @_;
    $self->sqitch->info('  - ', $step->format_name);
    # XXX Start a transaction and lock the steps table.
    $self->run_file($step->revert_file);
    $self->log_revert_step($step);
}

sub latest_step {
    my $self = shift;
    my $step_id = $self->latest_step_id;
    return defined $step_id ? $self->plan->get( $step_id ) : undef;
}

sub initialized {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented initialized()" );
}

sub initialize {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented initialize()" );
}

sub run_file {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented run_file()" );
}

sub run_handle {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented run_handle()" );
}

sub log_deploy_step {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_deploy_step()" );
}

sub log_fail_step {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_fail_step()" );
}

sub log_revert_step {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_revert_step()" );
}

sub is_deployed_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented is_deployed_tag()" );
}

sub is_deployed_step {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented is_deployed_step()" );
}

sub check_requires {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented check_requires()" );
}

sub check_conflicts {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented check_conflicts()" );
}

sub latest_step_id {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented latest_step_id()" );
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine - Sqitch Deployment Engine

=head1 Synopsis

  my $engine = App::Sqitch::Engine->new( sqitch => $sqitch );

=head1 Description

App::Sqitch::Engine provides the base class for all Sqitch storage engines.
Most likely this will not be of much interest to you unless you are hacking on
the engine code.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine->config_vars;

Returns a hash of names and types to use for configuration variables for the
engine. These can be set under the C<core.$engine_name> section in any
configuration file.

The keys in the returned hash are the names of the variables. The values are
the data types. Valid data types include:

=over

=item C<any>

=item C<int>

=item C<num>

=item C<bool>

=item C<bool-or-int>

=back

Values ending in C<+> (a plus sign) may be specified multiple times. Example:

  (
      client  => 'any',
      db_name => 'any',
      host    => 'any',
      port    => 'int',
      set     => 'any+',
  )

In this example, the C<port> variable will be stored and retrieved as an
integer. The C<set> variable may be of any type and may be included multiple
times. All the other variables may be of any type.

By default, App::Sqitch::Engine returns an empty list. Subclasses for
supported engines will return more.

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Engine->load(%params);

A factory method for instantiating Sqitch engines. It loads the subclass for
the specified engine and calls C<new>, passing the Sqitch object. Supported
parameters are:

=over

=item C<sqitch>

The App::Sqitch object driving the whole thing.

=back

=head3 C<new>

  my $engine = App::Sqitch::Engine->new(%params);

Instantiates and returns a App::Sqitch::Engine object.

=head2 Instance Methods

=head3 C<name>

  my $name = $engine->name;

The name of the engine. Defaults to the last part of the package name, so as a
rule you should not need to override it, since it is that string that Sqitch
uses to find the engine class.

=head3 C<destination>

  my $destination = $engine->destination;

Returns the name of the destination database. This will usually be the same as
the configured database name or the value of the C<--db-name> option. Hover,
subclasses may override it to provide other values, such as when neither of
the above have values but there is nevertheless a default value assumed by the
engine. Used internally to name the destination in status messages.

=head3 C<deploy>

  $engine->deploy($to_target);
  $engine->deploy($to_target, $mode);

Deploys changes to the destination database, starting with the current
deployment state, and continuing to C<$to_target>. C<$to_target> must be a
valid target specification as passable to the C<index_of()> method of
L<App::Sqitch::Plan>. If C<$to_target> is not specified, all changes will be
applied.

The second argument specifies the reversion mode in the case of deployment
failure. The allowed values are:

=over

=item C<all>

In the event of failure, revert all deployed changes, back to the point at
which deployment started. This is the default.

=item C<tag>

In the event of failure, revert all deployed changes to the last
successfully-applied tag. If no tags were applied during this deployment, all
changes will be reverted to the pint at which deployment began.

=item C<step>

In the event of failure, no changes will be reverted. This is on the
assumption that a step failure is total, and the step may be applied again.

=back

Note that, in the event of failure, if a reversion fails, the destination
database B<may be left in a corrupted state>. Write your revert scripts
carefully!

=head3 C<revert>

  $engine->revert($tag);

Reverts the L<App::Sqitch::Plan::Tag> from the database, including all of its
associated steps.

=head3 C<deploy_step>

  $engine->deploy_step($step);

Used internally by C<deploy()> to deploy an individual step.

=head3 C<revert_step>

  $engine->revert_step($step);

Used internally by C<revert()> (and, by C<deploy()> when a deploy fails) to
revert an individual step.

=head3 C<is_deployed>

  say "Tag deployed"  if $engine->is_deployed($tag);
  say "Step deployed" if $engine->is_deployed($step);

Convenience method that dispatches to C<is_deployed_tag()> or
C<is_deployed_step()> as appropriate to its argument.

=head2 Abstract Instance Methods

These methods must be overridden in subclasses.

=head3 C<initialized>

  $engine->initialize unless $engine->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $engine->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema
and/or tables. Should be overridden by subclasses. This implementation throws
an exception

=head3 C<is_deployed_tag>

  say "Tag deployed"  if $engine->is_deployed_tag($tag);

Should return true if the tag has been deployed to the database, and false if
it has not.

=head3 C<is_deployed_step>

  say "Step deployed"  if $engine->is_deployed_step($step);

Should return true if the step has been deployed to the database, and false if
it has not.

=head3 C<log_deploy_step>

  $engine->log_deploy_step($step);

Should write to the database metadata and history the records necessary to
indicate that the step has been deployed.

=head3 C<log_fail_step>

  $engine->log_fail_step($step);

Should write to the database event history a record reflecting that deployment
of the step failed.

=head3 C<log_revert_step>

  $engine->log_revert_step($step);

Should write to and/or remove from the database metadata and history the
records necessary to indicate that the step has been reverted.

=head3 C<check_requires>

  if ( my @requires = $engine->requires($step) ) {
      die "Step requires undeployed steps: @requires\n";
  }

Returns the names of any steps required by the specified step that are not
currently deployed to the database. If none are returned, the requirements are
presumed to be satisfied.

=head3 C<check_conflicts>

  if ( my @conflicts = $engine->conflicts($step) ) {
      die "Step conflicts with previously deployed steps: @conflicts\n";
  }

Returns the names of any currently-deployed steps that conflict with specified
step. If none are returned, there are presumed to be no conflicts.

If any of the steps that conflict with the specified step have been deployed
to the database, their names should be returned by this method. If no names
are returned, it's because there are no conflicts.

=head3 C<latest_step_id>

  my $step_id = $engine->latest_step_id;

Returns the ID of the most recently applied step.

=head3 C<latest_step>

  my $step = $engine->latest_step;

Returns the L<App::Sqitch::Plan::Step> object representing the most recently
applied step.

=head3 C<run_file>

  $engine->run_file($file);

Should execute the commands in the specified file. This will generally be an
SQL file to run through the engine's native client.

=head3 C<run_handle>

  $engine->run_handle($file_handle);

Should execute the commands in the specified file handle. The file handle's
contents should be piped to the engine's native client.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

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
