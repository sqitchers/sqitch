package App::Sqitch::Engine;

use 5.010;
use Moose;
use strict;
use utf8;
use Try::Tiny;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use namespace::autoclean;

our $VERSION = '0.939';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
    handles  => { destination => 'db_name', plan => 'plan' },
);

has start_at => (
    is  => 'rw',
    isa => 'Str'
);

has _variables => (
    traits  => ['Hash'],
    is      => 'rw',
    isa     => 'HashRef[Str]',
    default => sub { {} },
    handles => {
        variables       => 'elements',
        set_variables   => 'set',
        clear_variables => 'clear',
    },
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
        hurl {
            ident   => 'deploy',
            message => __ 'Nothing to deploy (up-to-date)',
            exitval => 1,
        };

    } elsif ($plan->position == -1) {
        # Initialize the database, if necessary.
        unless ($self->initialized) {
            $sqitch->info(__x(
                'Adding metadata tables to {destination}',
                destination => $self->destination,
            ));
            $self->initialize;
        }
        $self->register_project;

    } else {
        # Make sure that $to_index is greater than the current point.
        hurl deploy => __ 'Cannot deploy to an earlier target; use "revert" instead'
            if $to_index < $plan->position;
    }

    $sqitch->info(
        defined $to ? __x(
            'Deploying changes through {target} to {destination}',
            destination => $self->destination,
            target      => $plan->change_at($to_index)->format_name_with_tags
        ) : __x(
            'Deploying changes to {destination}',
            destination => $self->destination,
        )
    );

    $mode ||= 'all';
    my $meth = $mode eq 'change' ? '_deploy_by_change'
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

    my @change_ids;

    if (defined $to) {
        my $change = $plan->get($to) // hurl revert => __x(
            'Unknown revert target: "{target}"',
            target => $to,
        );

        @change_ids = $self->deployed_change_ids_since($change) or hurl revert => __x(
            'Target not deployed: "{target}"',
            target => $to,
        );

        $sqitch->info(__x(
            'Reverting changes to {target} from {destination}',
            target      => $change->format_name_with_tags,
            destination => $self->destination,
        ));
    } else {
        @change_ids = $self->deployed_change_ids or hurl {
            ident   => 'revert',
            message => __ 'Nothing to revert (nothing deployed)',
            exitval => 1,
        };
        $sqitch->info(__x(
            'Reverting all changes from {destination}',
            destination => $self->destination,
        ));
    }

    # Get the list of changes to revert before we do actual work.
    my @changes = map {
        $plan->get($_) or do {
            # Couldn't find it by ID; try to find by name and tag.
            my $name = $self->name_for_change_id($_);
            $plan->get($name) or hurl revert => __x(
                'Could not find change "{change}" ({id}) in the plan',
                change => $name,
                id     => $_,
            );
        };
    } reverse @change_ids;

    # Do we want to support modes, where failures would re-deploy to previous
    # tag or all the way back to the starting point? This would be very much
    # like deploy() mode. I'm thinking not, as a failure on a revert is not
    # something you generaly want to recover from by deploying back to where
    # you started. But maybe I'm wrong?
    $self->revert_change($_) for @changes;

    return $self;
}

sub _deploy_by_change {
    my ( $self, $plan, $to_index ) = @_;

    # Just deploy each change. If any fails, we just stop.
    while ($plan->position < $to_index) {
        $self->deploy_change($plan->next);
    }

    return $self;
}

sub _rollback {
    my ($self, $tagged) = (shift, shift);
    my $sqitch = $self->sqitch;

    if (my @run = reverse @_) {
        $tagged = $tagged ? $tagged->format_name_with_tags : $self->start_at;
        $sqitch->vent(
            $tagged ? __x('Reverting to {target}', target => $tagged)
                 : __ 'Reverting all changes'
        );

        try {
            $self->revert_change($_) for @run;
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

    my ($last_tagged, @run);
    try {
        while ($plan->position < $to_index) {
            my $change = $plan->next;
            $self->deploy_change($change);
            push @run => $change;
            if ($change->tags) {
                @run = ();
                $last_tagged = $change;
            }
        }
    } catch {
        if (my $ident = eval{ $_->ident }) {
            $self->sqitch->vent($_->message) unless $ident eq 'private'
        } else {
            $self->sqitch->vent($_);
        }
        $self->_rollback($last_tagged, @run);
    };

    return $self;
}

sub _deploy_all {
    my ( $self, $plan, $to_index ) = @_;

    my @run;
    try {
        while ($plan->position < $to_index) {
            my $change = $plan->next;
            $self->deploy_change($change);
            push @run => $change;
        }
    } catch {
        if (my $ident = eval{ $_->ident }) {
            $self->sqitch->vent($_->message) unless $ident eq 'private'
        } else {
            $self->sqitch->vent($_);
        }
        $self->_rollback(undef, @run);
    };

    return $self;
}

sub _sync_plan {
    my $self = shift;
    my $plan = $self->sqitch->plan;

    if (my $id = $self->latest_change_id) {
        my $idx = $plan->index_of($id) // hurl plan => __x(
            'Cannot find {target} in the plan',
            target => $id
        );

        my $change = $plan->change_at($idx);
        if ($id eq $change->old_id) {
            # Old IDs need to be replaced.
            $idx    = $self->_update_ids;
            $change = $plan->change_at($idx);
        }

        $plan->position($idx);
        if (my @tags = $change->tags) {
            $self->start_at( $change->format_name . $tags[-1]->format_name );
        } else {
            $self->start_at( $change->format_name );
        }

    } else {
        $plan->reset;
    }
    return $plan;
}

sub _update_ids {
    # We do nothing but inform, by default.
    my $self = shift;
    $self->sqitch->info(__x(
        'Updating legacy change and tag IDs in {destination}',
        destination => $self->destination,
    ));
    return $self;
}

sub is_deployed {
    my ($self, $thing) = @_;
    return $thing->isa('App::Sqitch::Plan::Tag')
        ? $self->is_deployed_tag($thing)
        : $self->is_deployed_change($thing);
}

sub deploy_change {
    my ( $self, $change ) = @_;
    my $sqitch = $self->sqitch;
    $sqitch->info('  + ', $change->format_name_with_tags);
    $self->begin_work($change);

    # Check for conflicts.
    if (my @conflicts = grep {
        $self->change_id_for_depend($_)
    } $change->conflicts) {
        hurl deploy => __nx(
            'Conflicts with previously deployed change: {changes}',
            'Conflicts with previously deployed changes: {changes}',
            scalar @conflicts,
            changes => join ' ', map { $_->as_string } @conflicts,
        )
    }

    # Check for dependencies.
    if (my @required = grep {
        !$_->resolved_id( $self->change_id_for_depend($_) )
    } $change->requires) {
        hurl deploy => __nx(
            'Missing required change: {changes}',
            'Missing required changes: {changes}',
            scalar @required,
            changes => join ' ', map { $_->as_string } @required,
        );
    }

    return try {
        $self->run_file($change->deploy_file);
        try {
            $self->log_deploy_change($change);
        } catch {
            # Oy, our logging died. Rollback.
            $sqitch->vent(eval { $_->message } // $_);
            $self->rollback_work($change);

            # Begin work and run the revert.
            try {
                $self->sqitch->info('  - ', $change->format_name_with_tags);
                $self->begin_work($change);
                $self->run_file($change->revert_file);
            } catch {
                # Oy, the revert failed. Just emit the error.
                $sqitch->vent(eval { $_->message } // $_);
            };
            hurl private => __ 'Deploy failed';
        };
    } finally {
        $self->finish_work($change);
    } catch {
        $self->log_fail_change($change);
        die $_;
    };
}

sub revert_change {
    my ( $self, $change ) = @_;
    $self->sqitch->info('  - ', $change->format_name_with_tags);
    $self->begin_work($change);

    if (my @requiring = $self->changes_requiring_change($change)) {
        my $proj = $self->plan->project;
        # XXX Include change_id in the output?
        hurl revert => __nx(
            'Required by currently deployed change: {changes}',
            'Required by currently deployed changes: {changes}',
            scalar @requiring,
            changes => join ' ', map {
                ($_->{project} eq $proj ? '' : "$_->{project}:" )
                . $_->{change}
                . ($_->{asof_tag} // '')
            } @requiring,
        );
    }

    try {
        $self->run_file($change->revert_file);
        try {
            $self->log_revert_change($change);
        } catch {
            # Oy, our logging died. Rollback and revert this change.
            $self->sqitch->vent(eval { $_->message } // $_);
            $self->rollback_work($change);
            hurl revert => 'Revert failed';
        };
    } finally {
        $self->finish_work($change);
    } catch {
        die $_;
    };
}

sub begin_work  { shift }
sub finish_work { shift }
sub rollback_work { shift }

sub earliest_change {
    my $self = shift;
    my $change_id = $self->earliest_change_id(@_) // return undef;
    return $self->sqitch->plan->get( $change_id );
}

sub latest_change {
    my $self = shift;
    my $change_id = $self->latest_change_id(@_) // return undef;
    return $self->sqitch->plan->get( $change_id );
}

sub initialized {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented initialized()";
}

sub initialize {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented initialize()";
}

sub register_project {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented register_project()";
}

sub run_file {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented run_file()";
}

sub run_handle {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented run_handle()";
}

sub log_deploy_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_deploy_change()";
}

sub log_fail_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_fail_change()";
}

sub log_revert_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_revert_change()";
}

sub is_deployed_tag {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented is_deployed_tag()";
}

sub is_deployed_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented is_deployed_change()";
}

sub change_id_for_depend {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented change_id_for_depend()";
}

sub earliest_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented earliest_change_id()";
}

sub latest_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented latest_change_id()";
}

sub deployed_change_ids {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented deployed_change_ids()";
}

sub deployed_change_ids_since {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented deployed_change_ids_since()";
}

sub changes_requiring_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented changes_requiring_change()";
}

sub name_for_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented name_for_change_id()";
}

sub registered_projects {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented registered_projects()";
}

sub current_state {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_state()";
}

sub current_changes {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_changes()";
}

sub current_tags {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_tags()";
}

sub search_events {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented search_events()";
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

=head3 variables

=head3 set_variables

=head3 clear_variables

  my %vars = $engine->variables;
  $engine->set_variables(foo => 'bar', baz => 'hi there');
  $engine->clear_variables;

Get, set, and clear engine variables. Variables are defined as key/value pairs
to be passed to the engine client in calls to C<deploy> and C<revert>, if the
client supports variables. For example, the
L<PostgreSQL engine|App::Sqitch::Engine::pg> passes all the variables to
the C<psql> client via the C<--set> option.

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

=item C<change>

In the event of failure, no changes will be reverted. This is on the
assumption that a change failure is total, and the change may be applied again.

=back

Note that, in the event of failure, if a reversion fails, the destination
database B<may be left in a corrupted state>. Write your revert scripts
carefully!

=head3 C<revert>

  $engine->revert($tag);

Reverts the L<App::Sqitch::Plan::Tag> from the database, including all of its
associated changes.

=head3 C<deploy_change>

  $engine->deploy_change($change);

Used internally by C<deploy()> to deploy an individual change.

=head3 C<revert_change>

  $engine->revert_change($change);

Used internally by C<revert()> (and, by C<deploy()> when a deploy fails) to
revert an individual change.

=head3 C<is_deployed>

  say "Tag deployed"  if $engine->is_deployed($tag);
  say "Change deployed" if $engine->is_deployed($change);

Convenience method that dispatches to C<is_deployed_tag()> or
C<is_deployed_change()> as appropriate to its argument.

=head3 C<earliest_change>

  my $change = $engine->earliest_change;

Returns the L<App::Sqitch::Plan::Change> object representing the earliest
applied change. With the optional C<$offset> argument, the returned change
will be the offset number of changes following the earliest change.


=head3 C<latest_change>

  my $change = $engine->latest_change;
  my $change = $engine->latest_change($offset);

Returns the L<App::Sqitch::Plan::Change> object representing the latest
applied change. With the optional C<$offset> argument, the returned change
will be the offset number of changes before the latest change.

=head2 Abstract Instance Methods

These methods must be overridden in subclasses.

=head3 C<begin_work>

  $engine->begin_work($change);

This method is called just before a change is deployed or reverted. It should
create a lock to prevent any other processes from making changes to the
database, to be freed in C<finish_work> or C<rollback_work>.

=head3 C<finish_work>

  $engine->finish_work($change);

This method is called after a change has been deployed or reverted. It should
unlock the lock created by C<begin_work>.

=head3 C<rollback_work>

  $engine->rollback_work($change);

This method is called after a change has been deployed or reverted and the
logging of that change has failed. It should rollback changes started by
C<begin_work>.

=head3 C<initialized>

  $engine->initialize unless $engine->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $engine->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema
and/or tables. Should be overridden by subclasses. This implementation throws
an exception

=head3 C<register_project>

  $engine->register_project;

Registers the current project plan in the database. The implementation should
insert the project name and URI if they have not already been inserted. If a
project with the same name but different URI already exists, an exception
should be thrown.

=head3 C<is_deployed_tag>

  say 'Tag deployed' if $engine->is_deployed_tag($tag);

Should return true if the L<tag|App::Sqitch::Plan::Tag> has been applies to
the database, and false if it has not.

=head3 C<is_deployed_change>

  say 'Change deployed' if $engine->is_deployed_change($change);

Should return true if the L<change|App::Sqitch::Plan::Change> has been
deployed to the database, and false if it has not.

=head3 C<change_id_for_depend>

  say 'Dependency satisfied' if $engine->change_id_for_depend($depend);

Returns the change ID for a L<dependency|App::Sqitch::Plan::Depend>, if the
dependency resolves to a change currently deployed to the database. Returns
C<undef> if the dependency resolves to no currently-deployed change.

=head3 C<changes_requiring_change>

  my @requiring = $engine->changes_requiring_change($change);

Returns a list of hash references representing currently deployed changes that
require the passed change. When this method returns one or more hash
references, the change should not be reverted. Each hash reference should
contain the following keys:

=over

=item C<change_id>

The requiring change ID.

=item C<change>

The requiring change name.

=item C<project>

The project the requiring change is from.

=item C<asof_tag>

Name of the first tag to be applied after the requiring change was deployed,
if any.

=back

=head3 C<log_deploy_change>

  $engine->log_deploy_change($change);

Should write to the database metadata and history the records necessary to
indicate that the change has been deployed.

=head3 C<log_fail_change>

  $engine->log_fail_change($change);

Should write to the database event history a record reflecting that deployment
of the change failed.

=head3 C<log_revert_change>

  $engine->log_revert_change($change);

Should write to and/or remove from the database metadata and history the
records necessary to indicate that the change has been reverted.

=head3 C<earliest_change_id>

  my $change_id = $engine->earliest_change_id($offset);

Returns the ID of the earliest applied change from the current project. With
the optional C<$offset> argument, the ID of the change the offset number of
changes following the earliest change will be returned.

=head3 C<latest_change_id>

  my $change_id = $engine->latest_change_id;
  my $change_id = $engine->latest_change_id($offset);

Returns the ID of the latest applied change from the current project.
With the optional C<$offset> argument, the ID of the change the offset
number of changes before the latest change will be returned.

=head3 C<deployed_change_ids>

  my @change_ids = $engine->deployed_change_ids;

Returns a list of all deployed change IDs from the current project in the
order in which they were deployed.

=head3 C<deployed_change_ids_since>

  my @change_ids = $engine->deployed_change_ids_since($change);

Returns a list of change IDs for changes from the current project deployed
after the specified change.

=head3 C<name_for_change_id>

  my $change_name = $engine->name_for_change_id($change_id);

Returns the name of the change identified by the ID argument. If a tag was
applied to a change after that change, the name will be returned with the tag
qualification, e.g., C<app_user@beta>. This value should be suitable for
uniquely identifying the change, and passing to the C<get> or C<index_of>
methods of L<App::Sqitch::Plan>.

=head3 C<registered_projects>

  my @projects = $engine->registered_projects;

Returns a list of the names of Sqitch projects registered in the database.

=head3 C<current_state>

  my $state = $engine->current_state;
  my $state = $engine->current_state($project);

Returns a hash reference representing the current project deployment state of
the database, or C<undef> if the database has no changes deployed. If a
project name is passed, the state will be returned for that project. Otherwise,
the state will be returned for the local project.

The hash contains information about the last successfully deployed change, as
well as any associated tags. The keys to the hash should include:

=over

=item C<project>

The name of the project for which the state is reported.

=item C<change_id>

The current change ID.

=item C<change>

The current change name.

=item C<note>

A brief description of the change.

=item C<tags>

An array reference of the names of associated tags.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was deployed.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head3 C<current_changes>

  my $iter = $engine->current_changes;
  my $iter = $engine->current_changes($project);
  while (my $change = $iter->()) {
      say '* ', $change->{change};
  }

Returns a code reference that iterates over a list of the currently deployed
changes in reverse chronological order. If a project name is not passed, the
current project will be assumed. Each change is represented by a hash
reference containing the following keys:

=over

=item C<change_id>

The current change ID.

=item C<change>

The current change name.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was deployed.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head3 C<current_tags>

  my $iter = $engine->current_tags;
  my $iter = $engine->current_tags($project);
  while (my $tag = $iter->()) {
      say '* ', $tag->{tag};
  }

Returns a code reference that iterates over a list of the currently deployed
tags in reverse chronological order. If a project name is not passed, the
current project will be assumed. Each tag is represented by a hash reference
containing the following keys:

=over

=item C<tag_id>

The tag ID.

=item C<tag>

The name of the tag.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
tag was applied.

=item C<committer_name>

Name of the user who applied the tag.

=item C<committer_email>

Email address of the user who applied the tag.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
tag was added to the plan.

=item C<planner_name>

Name of the user who added the tag to the plan.

=item C<planner_email>

Email address of the user who added the tag to the plan.

=back

=head3 C<search_events>

  my $iter = $engine->search_events( %params );
  while (my $change = $iter->()) {
      say '* $change->{event}ed $change->{change}";
  }

Searches the deployment event log and returns an iterator code reference with
the results. If no parameters are provided, a list of all events will be
returned from the iterator reverse chronological order. The supported parameters
are:

=over

=item C<event>

An array of the type of event to search for. Allowed values are "deploy",
"revert", and "fail".

=item C<project>

Limit the events to those with project names matching the specified regular
expression.

=item C<change>

Limit the events to those with changes matching the specified regular
expression.

=item C<committer>

Limit the events to those logged for the actions of the committers with names
matching the specified regular expression.

=item C<limit>

Limit the number of events to the specified number.

=item C<offset>

Skip the specified number of events.

=item C<direction>

Return the results in the specified order, which must be a value matching
C</^(:?a|de)sc/i> for "ascending" or "descending".

=back

Each event is represented by a hash reference containing the following keys:

=over

=item C<event>

The type of event, which is one of:

=over

=item C<deploy>

=item C<revert>

=item C<fail>

=back

=item C<project>

The name of the project with which the change is associated.

=item C<change_id>

The change ID.

=item C<change>

The name of the change.

=item C<note>

A brief description of the change.

=item C<tags>

An array reference of the names of associated tags.

=item C<requires>

An array reference of the names of any changes required by the change.

=item C<conflicts>

An array reference of the names of any changes that conflict with the change.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
event was logged.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

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
