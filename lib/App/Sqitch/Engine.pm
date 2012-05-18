package App::Sqitch::Engine;

use v5.10.1;
use Moose;
use utf8;
use Try::Tiny;
use namespace::autoclean;

our $VERSION = '0.31';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
    handles  => { target => 'db_name' },
);

sub load {
    my ( $class, $p ) = @_;

    # We should have a command.
    die 'Missing "engine" parameter to load()' unless $p->{engine};

    # Load the engine class.
    my $pkg = __PACKAGE__ . "::$p->{engine}";
    eval "require $pkg" or die $@;
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

sub _rollback_steps {
    my $self   = shift;
    my $tag    = shift;
    my @steps  = @_;
    my $sqitch = $self->sqitch;
    $sqitch->vent('Reverting previous steps for tag ', $tag->name)
        if @steps;

    try {
        for my $step (reverse @steps) {
            $sqitch->info('  - ', $step->name);
            $self->revert_step($step);
        }
        $self->rollback_deploy_tag($tag);
    } catch {
        # Sucks when this happens.
        # XXX Add message about state corruption?
        $sqitch->debug($_);
        $sqitch->vent(
            'Error rolling back ', $tag->name, $/,
            'The schema will need to be manually repaired'
        );
    };

    return $self;
}

sub deploy {
    my ($self, $tag) = @_;
    my $sqitch = $self->sqitch;

    return $sqitch->info(
        'Tag ', $tag->name, ' already deployed to ', $self->target
    ) if $self->is_deployed_tag($tag);

    return $sqitch->warn('Tag ', $tag->name, ' has no steps; skipping')
        unless $tag->steps;

    $sqitch->info('Deploying ', $tag->name, ' to ', $self->target);

    my @run;
    try {
        $self->begin_deploy_tag($tag);
        for my $step ($tag->steps) {
            if ( $self->is_deployed_step($step) ) {
                $sqitch->info('    ', $step->name, ' already deployed');
                next;
            }
            $sqitch->info('  + ', $step->name);

            # Check for conflicts.
            if (my @conflicts = $self->check_conflicts($step)) {
                my $pl = @conflicts > 1 ? 's' : '';
                $sqitch->vent(
                    "Conflicts with previously deployed step$pl: ",
                    join ' ', @conflicts
                );
                $self->_rollback_steps($tag, @run);
                $sqitch->fail( 'Aborting deployment of ', $tag->name );
            }

            # Check for prerequisites.
            if (my @required = $self->check_requires($step)) {
                my $pl = @required > 1 ? 's' : '';
                $sqitch->vent(
                    "Missing required step$pl: ",
                    join ' ', @required
                );
                $self->_rollback_steps($tag, @run);
                $sqitch->fail( 'Aborting deployment of ', $tag->name );
            }

            # Go for it.
            try {
                $self->deploy_step($step);
                push @run => $step;
            } catch {
                # Ruh-roh.
                $self->log_fail_step($step);
                die $_;
            };
        }
        $self->commit_deploy_tag($tag);
    } catch {
        # Whoops! Revert completed steps.
        $sqitch->debug($_);
        $self->_rollback_steps($tag, @run);
        $sqitch->fail( 'Aborting deployment of ', $tag->name );
    };

    return $self;
}

sub revert {
    my ($self, $tag) = @_;
    my $sqitch = $self->sqitch;

    return $sqitch->info(
        'Tag ', $tag->name, ' is not deployed to ', $self->target
    ) unless $self->is_deployed_tag($tag);

    $sqitch->info('Reverting ', $tag->name, ' from ', $self->target);

    try {
        $self->begin_revert_tag($tag);
    } catch {
        $sqitch->debug($_);
        $sqitch->fail( 'Aborting reversion of ', $tag->name );
    };

    # Revert only deployed steps.
    for my $step ( reverse $self->deployed_steps_for($tag) ) {
        $sqitch->info('  - ', $step->name);
        try {
            $self->revert_step($step);
        } catch {
            # Whoops! We're fucked.
            # XXX do something to mark the state as corrupted.
            $sqitch->debug($_);
            $sqitch->fail(
                'Error reverting step ', $step->name, $/,
                'The schema will need to be manually repaired'
            );
        };
    }

    try {
        $self->commit_revert_tag($tag);
    } catch {
        $sqitch->debug($_);
        $sqitch->fail( "Error removing tag ", $tag->name );
    };

    return $self;
}

sub is_deployed {
    my ($self, $thing) = @_;
    return $thing->isa('App::Sqitch::Plan::Tag')
        ? $self->is_deployed_tag($thing)
        : $self->is_deployed_step($thing);
}

sub deploy_step {
    my ( $self, $step ) = @_;
    $self->run_file($step->deploy_file);
    $self->log_deploy_step($step);
}

sub revert_step {
    my ( $self, $step ) = @_;
    $self->run_file($step->revert_file);
    $self->log_revert_step($step);
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

sub begin_deploy_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented begin_deploy_tag()" );
}

sub commit_deploy_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented commit_deploy_tag()" );
}

sub rollback_deploy_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented rollback_deploy_tag()" );
}

sub begin_revert_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented begin_revert_tag()" );
}

sub commit_revert_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented commit_revert_tag()" );
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

sub deployed_steps_for {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented deployed_steps_for()" );
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

sub current_tag_name {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented current_tag_name()" );
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

=head3 C<target>

  my $target = $engine->target;

Returns the name of the target database. This will usually be the same as the
configured database name or the value of the C<--db-name> option. Hover,
subclasses may override it to provide other values, such as when neither of
the above have values but there is nevertheless a default value assumed by the
engine. Used internally by C<deploy()> and C<revert()> in status messages.

=head3 C<deploy>

  $engine->deploy($tag);

Deploys the L<App::Sqitch::Plan::Tag> to the database, including all of its
associated steps.

=head3 C<deploy_step>

  $engine->deploy_step($step);

Used internally by C<deploy()> to deploy an individual step.

=head3 C<revert>

  $engine->revert($tag);

Reverts the L<App::Sqitch::Plan::Tag> from the database, including all of its
associated steps.

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

=head3 C<begin_deploy_tag>

  $engine->begin_deploy_tag($tag);

Start deploying the tag. The engine may need to write the tag to the database,
create locks to control the deployment, etc.

=head3 C<commit_deploy_tag>

  $engine->commit_deploy_tag($tag);

Commit a tag deployment. The engine should clean up anything started in
C<begin_deploy_tag()>.

=head3 C<rollback_deploy_tag>

  $engine->rollback_deploy_tag($tag);

Roll back a tag deployment. The engine should remove the tag record and commit
its changes.

=head3 C<log_deploy_step>

  $engine->log_deploy_step($step);

Should write to the database metadata and history the records necessary to
indicate that the step has been deployed.

=head3 C<log_fail_step>

  $engine->log_fail_step($step);

Should write to the database event history a record reflecting that deployment
of the step failed.

=head3 C<begin_revert_tag>

  $engine->begin_revert_tag($tag);

Start reverting the tag. The engine may need to update the database, create
locks to control the reversion, etc.

=head3 C<commit_revert_tag>

  $engine->commit_revert_tag($tag);

Commit a tag reversion. The engine should clean up anything started in
C<begin_revert_tag()>.

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

=head3 C<current_tag_name>

  my $tag_name $engine->current_tag_name;

Returns one tag name from the most recently deployed tag.

=head3 C<run_file>

  $engine->run_file($file);

Should execute the commands in the specified file. This will generally be an
SQL file to run through the engine's native client.

=head3 C<run_handle>

  $engine->run_handle($file_handle);

Should execute the commands in the specified file handle. The file handle's
contents should be piped to the engine's native client.

=head3 C<deployed_steps_for>

  my @steps = $engine->deployed_steps_for($tag);

Should return a list of steps currently deployed to the database for the
specified tag, in an order appropriate to satisfy dependencies.

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
