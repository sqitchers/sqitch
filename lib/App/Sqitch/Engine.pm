package App::Sqitch::Engine;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use namespace::autoclean;
use Moose;

our $VERSION = '0.30';

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

sub _revert_steps {
    my $self   = shift;
    my $tag    = shift;
    my $sqitch = $self->sqitch;
    $sqitch->vent('Reverting previous steps for tag ', $tag->name);

    for my $step (reverse @_) {
        $sqitch->info('  - ', $step->name);
        try {
            $self->revert_step($step);
        } catch {
            # Sucks when this happens.
            # XXX Add message about state corruption?
            $sqitch->debug($_);
            $sqitch->vent(
                'Error reverting step ', $step->name, $/,
                'The schema will need to be manually repaired'
            );
            # Damn you Try::Tiny and your code refs!
            return 0;
        } or return;
    }
}

sub deploy {
    my ($self, $tag) = @_;
    my $sqitch = $self->sqitch;

    return $sqitch->info(
        'Tag ', $tag->name, ' already deployed to ', $self->target
    ) if $self->is_deployed_tag($tag);

    $sqitch->info('Deploying ', $tag->name, ' to ', $self->target);
    unless ($tag->steps) {
        $sqitch->warn('Tag ', $tag->name, ' has no steps; skipping');
        return $self;
    }

    my @run;
    for my $step ($tag->steps) {
        if ( $self->is_deployed_step($step) ) {
            $sqitch->info('    ', $step->name, ' already deployed');
            next;
        }

        $sqitch->info('  + ', $step->name);
        try {
            $self->deploy_step($step);
            push @run => $step;
        } catch {
            # Whoops! Revert completed steps.
            $sqitch->debug($_);
            $self->_revert_steps($tag, @run) if @run;
            $sqitch->fail( 'Aborting deployment of ', $tag->name );
        };
    }

    # Success!
    try {
        $self->log_deploy_tag($tag);
    } catch {
        # Whoops! Revert completed steps.
        $sqitch->debug($_);
        $self->_revert_steps($tag, @run);
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

    for my $step (reverse $tag->steps) {
        unless ( $self->is_deployed_step($step) ) {
            $sqitch->info('    ', $step->name, ' not deployed');
            next;
        }

        $sqitch->info('  - ', $step->name);
        try {
            $self->revert_step($step);
        } catch {
            # Whoops! We're fucked.
            # XXX do something to mark the state as corrupted.
            $sqitch->debug($_);
            $sqitch->fail(
                "Error reverting step ", $step->name, $/,
                'The schema will need to be manually repaired'
            );
        };
    }

    try {
        $self->log_revert_tag($tag);
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

sub log_revert_step {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_revert_step()" );
}

sub log_deploy_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_deploy_tag()" );
}

sub log_revert_tag {
    my $class = ref $_[0] || $_[0];
    require Carp;
    Carp::confess( "$class has not implemented log_revert_tag()" );
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

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine - Sqitch Deployment Engine

=head1 Synopsis

  my $engine = App::Sqitch::Engine->new( sqitch => $sqitch );

=head1 Description

App::Sqitch::Engine provides the base class for all Sqitch storage engines.

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

=head3 C<initialized>

  $engine->initialize unless $engine->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $engine->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema
and/or tables. Should be overridden by subclasses. This implementation throws
an exception

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
