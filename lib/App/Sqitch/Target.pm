package App::Sqitch::Target;

use 5.010;
use Moo;
use strict;
use warnings;
use App::Sqitch::Types qw(Maybe URIDB Str Dir Engine Sqitch File Plan Bool);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use Path::Class qw(dir file);
use URI::db;
use namespace::autoclean;

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);
sub target { shift->name }

has uri      => (
    is       => 'ro',
    isa      => URIDB,
    required => 1,
    handles  => {
        engine_key => 'canonical_engine',
        dsn        => 'dbi_dsn',
    },
);

sub username { scalar shift->uri->user }

has password => (
    is       => 'ro',
    isa      => Maybe[Str],
    lazy    => 1,
    default => sub {
        $ENV{SQITCH_PASSWORD} || shift->uri->password
    }
);

has sqitch => (
    is       => 'ro',
    isa      => Sqitch,
    required => 1,
);

has engine => (
    is      => 'ro',
    isa     => Engine,
    lazy    => 1,
    default => sub {
        my $self   = shift;
        require App::Sqitch::Engine;
        App::Sqitch::Engine->load({
            sqitch => $self->sqitch,
            target => $self,
        });
    },
);

# TODO: core.$engine is deprecated. Remove this workaround and warning
# when it is removed.
our $WARNED  = $ENV{HARNESS_ACTIVE};
sub _engine_var {
    my ($self, $config, $ekey, $akey) = @_;
    return unless $ekey;
    if (my $val = $config->get( key => "engine.$ekey.$akey" )) {
        return $val;
    }

    # Look for the deprecated config section.
    my $val = $config->get( key => "core.$ekey.$akey" ) or return;
    return $val if $WARNED;
    App::Sqitch->warn(__x(
        "The core.{engine} config has been deprecated in favor of engine.{engine}.\nRun '{sqitch} engine update-config' to update your configurations.",
        engine => $ekey,
        sqitch => $0,
    ));
    $WARNED = 1;
    return $val;
}

sub _fetch {
    my ($self, $key) = @_;
    my $sqitch = $self->sqitch;
    if (my $val = $sqitch->options->{$key}) {
        return $val;
    }

    my $config = $sqitch->config;
    return $config->get( key => "target." . $self->name . ".$key" )
        || $self->_engine_var($config, scalar $self->engine_key, $key)
        || $config->get( key => "core.$key");
}

has registry => (
    is  => 'ro',
    isa => Str,
    lazy => 1,
    default => sub {
        my $self = shift;
        $self->_fetch('registry') || $self->engine->default_registry;
    },
);

has client => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        $self->_fetch('client') || do {
            my $client = $self->engine->default_client;
            return $client if $^O ne 'MSWin32';
            return $client if $client =~ /[.](?:exe|bat)$/;
            return $client . '.exe';
        };
    },
);

has plan_file => (
    is       => 'ro',
    isa      => File,
    lazy     => 1,
    default => sub {
        my $self = shift;
        if (my $f = $self->_fetch('plan_file') ) {
            return file $f;
        }
        return $self->top_dir->file('sqitch.plan')->cleanup;
    },
);

has plan => (
    is       => 'ro',
    isa      => Plan,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        App::Sqitch::Plan->new(
            sqitch => $self->sqitch,
            target => $self,
        );
    },
);

has top_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        dir shift->_fetch('top_dir') || ();
    },
);

has reworked_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('reworked_dir') ) {
            return dir $dir;
        }
        $self->top_dir;
    },
);

for my $script (qw(deploy revert verify)) {
    has "$script\_dir" => (
        is      => 'ro',
        isa     => Dir,
        lazy    => 1,
        default => sub {
            my $self = shift;
            if ( my $dir = $self->_fetch("$script\_dir") ) {
                return dir $dir;
            }
            $self->top_dir->subdir($script)->cleanup;
        },
    );
    has "reworked_$script\_dir" => (
        is      => 'ro',
        isa     => Dir,
        lazy    => 1,
        default => sub {
            my $self = shift;
            if ( my $dir = $self->_fetch("reworked_$script\_dir") ) {
                return dir $dir;
            }
            $self->reworked_dir->subdir($script)->cleanup;
        },
    );
}

has extension => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        shift->_fetch('extension') || 'sql';
    },
);

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };

    # Fetch params. URI can come from passed name.
    my $sqitch = $p->{sqitch} or return $p;
    my $name   = $p->{name} || '';
    my $uri    = $p->{uri};

    # If we have a URI up-front, it's all good.
    if ($uri) {
        unless ($name) {
            # Set the URI as the name, sans password.
            if ($uri->password) {
                $uri = $uri->clone;
                $uri->password(undef);
            }
            $p->{name} = $uri->as_string;
        }
        return $p;
    }

    # XXX $merge for deprecated config.
    # Can also move $ekey just to block below when deprecated merge is removed.
    my ($ekey, $merge);
    my $config = $sqitch->config;

    # If no name, try to find one.
    if (!$name) {
        # There are a couple of places to look for a name.
        NAME: {
            # Look for an engine key.
            $ekey = $sqitch->options->{engine};
            unless ($ekey) {
                # No --engine, look for core target.
                if ( $uri = $config->get( key => 'core.target' ) ) {
                    # We got core.target. Merge all deprecated stuff.
                    $merge = 2;
                    $p->{name} = $name = $uri;
                    last NAME;
                }

                # No core target, look for an engine key.
                $ekey = $config->get(
                    key => 'core.engine'
                ) or hurl target => __(
                    'No engine specified; use --engine or set core.engine'
                );
            }

            # Find the name in the engine config, or fall back on a simple URI.
            $uri = $class->_engine_var($config, $ekey, 'target') || "db:$ekey:";
            $merge = 2; # Merge all deprecated stuff.
            $p->{name} = $name = $uri;
        }
    }

    # Now we should have a name. What is it?
    if ($name =~ /:/) {
        # The name is a URI.
        $uri = $name;
        $name  = $p->{name} = undef;
        $merge ||= 1; # At least merge options.
    } else {
        # Well then, there had better be a config with a URI.
        $uri = $config->get( key => "target.$name.uri" ) or do {
            # Die on no section or no URI.
            hurl target => __x(
                'Cannot find target "{target}"',
                target => $name
            ) unless %{ $config->get_section(
                section => "target.$name"
            ) };
            hurl target => __x(
                'No URI associated with target "{target}"',
                target => $name,
            );
        };
        $merge ||= 1; # At least merge options.
    }

    # Instantiate the URI.
    $uri = $p->{uri} = URI::db->new( $uri );
    $ekey ||= $uri->canonical_engine or hurl target => __x(
        'No engine specified by URI {uri}; URI must start with "db:$engine:"',
        uri => $uri->as_string,
    );

    if ($merge) {
        # Override parts with deprecated command-line options and config.
        my $opts    = $sqitch->options;
        my $econfig = $merge > 1
            ? $sqitch->config->get_section(section => "core.$ekey") || {}
            : {};

        if (%{ $econfig } && !%{ $sqitch->config->get_section(section => "engine.$ekey") || {} }) {
            App::Sqitch->warn(__x(
                "The core.{engine} config has been deprecated in favor of engine.{engine}.\nRun '{sqitch} engine update-config' to update your configurations.",
                engine => $ekey,
                sqitch => $0,
            )) unless $WARNED;
            $WARNED = 1;
        }

        if (my $host = $opts->{db_host}) {
            $uri->host($host);
        } elsif ($host = $econfig->{host}) {
            $uri->host($host) if $merge > 1;
        }

        if (my $port = $opts->{db_port}) {
            $uri->port($port);
        } elsif ($port = $econfig->{port}) {
            $uri->port($port) if $merge > 1;
        }

        if (my $user = $opts->{db_username}) {
            $uri->user($user);
        } elsif ($user = $econfig->{username}) {
            $uri->user($user) if $merge > 1;
        }

        if (my $pass = $econfig->{password}) {
            $uri->password($pass) if $merge > 1;
        }

        if (my $db = $opts->{db_name}) {
            $uri->dbname($db);
        } elsif ($db = $econfig->{db_name}) {
            $uri->dbname($db) if $merge > 1;
        }

    }

    unless ($name) {
        # Set the name.
        if ($uri->password) {
            # Remove the password from the name.
            my $tmp = $uri->clone;
            $tmp->password(undef);
            $p->{name} = $tmp->as_string;
        } else {
            $p->{name} = $uri->as_string;
        }
    }

    return $p;
}

sub all_targets {
    my ($class, %p) = @_;
    my $sqitch = $p{sqitch} or hurl 'Missing required argument: sqitch';
    my $config = $p{config} || $sqitch->config;
    my (@targets, %seen);
    my %dump = $config->dump;

    # First, load the default target.
    my $core = $dump{'core.target'} || do {
        if ( my $engine = $sqitch->options->{engine} || $dump{'core.engine'} ) {
            $dump{"engine.$engine.target"} || "db:$engine:";
        }
    };
    push @targets => $seen{$core} = $class->new(sqitch => $sqitch, name => $core)
        if $core;

    # Next, load named targets.
    for my $key (keys %dump) {
        next if $key !~ /^target[.]([^.]+)[.]uri$/;
        push @targets => $seen{$1} = $class->new(sqitch => $sqitch, name => $1)
            unless $seen{$1};
    }

    # Now, load the engine targets.
    while ( my ($key, $val) = each %dump ) {
        next if $key !~ /^engine[.]([^.]+)[.]target$/;
        push @targets => $seen{$val} = $class->new(sqitch => $sqitch, name => $val)
            unless $seen{$val};
        $seen{$1} = $seen{$val};
    }

    # Finally, load any engines for which no target name was specified.
    while ( my ($key, $val) = each %dump ) {
        my ($engine) = $key =~ /^engine[.]([^.]+)/ or next;
        next if $seen{$engine}++;
        my $uri = URI->new("db:$engine:");
        push @targets => $seen{$uri} = $class->new(sqitch => $sqitch, uri => $uri)
            unless $seen{$uri};
    }

    # Return all the targets.
    return @targets;
}

1;

__END__

=head1 Name

App::Sqitch::Target - Sqitch deployment target

=head1 Synopsis

  my $plan = App::Sqitch::Target->new(
      sqitch => $sqitch,
      name   => 'development',
  );
  $target->engine->deploy;

=head1 Description

App::Sqitch::Target provides collects, in one place, the
L<engine|App::Sqitch::Engine>, L<plan|App::Sqitch::Engine>, and file locations
required to carry out Sqitch commands. All commands should instantiate a
target to work with the plan or database.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $target = App::Sqitch::Target->new( sqitch => $sqitch );

Instantiates and returns an App::Sqitch::Target object. The most important
parameters are C<sqitch>, C<name>, and C<uri>. The constructor tries really
hard to figure out the proper name and URI during construction. If the C<uri>
parameter is passed, this is straight-forward: if no C<name> is passed,
C<name> will be set to the stringified format of the URI (minus the password,
if present).

Otherwise, when no URI is passed, the name and URI are determined by taking
the following steps:

=over

=item *

If there is no name, get the engine key from C<--engine> or the C<core.engine>
configuration option. If no key can be determined, an exception will be thrown.

=item *

Use the key to look up the target name in the C<engine.$engine.target>
configuration option. If none is found, use C<db:$key:>.

=item *

If the name contains a colon (C<:>), assume it is also the value for the URI.

=item *

Otherwise, it should be the name of a configured target, so look for a URI in
the C<target.$name.uri> configuration option.

=back

As a general rule, then, pass either a target name or URI string in the
C<name> parameter, and Sqitch will do its best to find all the relevant target
information. And if there is no name or URI, it will try to construct a
reasonable default from the command-line options or engine configuration.

=head3 C<all_targets>

Returns a list of all the targets defined by the local Sqitch configuration
file. Done by examining the configuration object to find all defined targets
and engines, as well as the default "core" target. Duplicates are removed and
the list returned. This method takes two parameters:

=over

=item * C<sqitch>

An L<App::Sqitch> object. Required.

=item * C<config>

An L<App::Sqitch::Config> object. If not passed, the object stored in the
Sqitch object's C<config> attribute will be used.

=back

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $target->sqitch;

Returns the L<App::Sqitch> object that instantiated the target.

=head3 C<name>

=head3 C<target>

  my $name = $target->name;
  $name = $target->target;

The name of the target. If there was no name specified, the URI will be used
(minus the password, if there is one).

=head3 C<uri>

  my $uri = $target->uri;

The L<URI::db> object encapsulating the database connection information.

=head3 C<username>

  my $username = $target->username;

Returns the target username, if any. The username is looked up from the URI.

=head3 C<password>

  my $password = $target->password;

Returns the target password, if any. The password is looked up from the URI
or the C<$SQITCH_PASSWORD> environment variable.

=head3 C<engine>

  my $engine = $target->engine;

A L<App::Sqitch::Engine> object to use for database interactions with the
target.

=head3 C<registry>

  my $registry = $target->registry;

The name of the registry used by the database. The value comes from one of
these options, searched in this order:

=over

=item * C<--registry>

=item * C<target.$name.registry>

=item * C<engine.$engine.registry>

=item * C<core.registry>

=item * Engine-specific default

=back

=head3 C<client>

  my $client = $target->client;

Path to the engine command-line client. The value comes from one of these
options, searched in this order:

=over

=item * C<--client>

=item * C<target.$name.client>

=item * C<engine.$engine.client>

=item * C<core.client>

=item * Engine-and-OS-specific default

=back

=head3 C<top_dir>

  my $top_dir = $target->top_dir;

The path to the top directory of the project. This directory generally
contains the plan file and subdirectories for deploy, revert, and verify
scripts. The value comes from one of these options, searched in this order:

=over

=item * C<--top-dir>

=item * C<target.$name.top_dir>

=item * C<engine.$engine.top_dir>

=item * C<core.top_dir>

=item * F<.>

=back

=head3 C<plan_file>

  my $plan_file = $target->plan_file;

The path to the plan file. The value comes from one of these options, searched
in this order:

=over

=item * C<--plan-file>

=item * C<target.$name.plan_file>

=item * C<engine.$engine.plan_file>

=item * C<core.plan_file>

=item * F<C<$top_dir>/sqitch.plan>

=back

=head3 C<deploy_dir>

  my $deploy_dir = $target->deploy_dir;

The path to the deploy directory of the project. This directory contains all
of the deploy scripts referenced by changes in the C<plan_file>. The value
comes from one of these options, searched in this order:

=over

=item * C<--dir deploy_dir=$deploy_dir>

=item * C<target.$name.deploy_dir>

=item * C<engine.$engine.deploy_dir>

=item * C<core.deploy_dir>

=item * F<C<$top_dir/deploy>>

=back

=head3 C<revert_dir>

  my $revert_dir = $target->revert_dir;

The path to the revert directory of the project. This directory contains all
of the revert scripts referenced by changes the C<plan_file>. The value comes
from one of these options, searched in this order:

=over

=item * C<--dir revert_dir=$revert_dir>

=item * C<target.$name.revert_dir>

=item * C<engine.$engine.revert_dir>

=item * C<core.revert_dir>

=item * F<C<$top_dir/revert>>

=back

=head3 C<verify_dir>

  my $verify_dir = $target->verify_dir;

The path to the verify directory of the project. This directory contains all
of the verify scripts referenced by changes in the C<plan_file>. The value
comes from one of these options, searched in this order:

=over

=item * C<--dir verify_dir=$verify_dir>

=item * C<target.$name.verify_dir>

=item * C<engine.$engine.verify_dir>

=item * C<core.verify_dir>

=item * F<C<$top_dir/verify>>

=back

=head3 C<reworked_dir>

  my $reworked_dir = $target->reworked_dir;

The path to the reworked directory of the project. This directory contains
subdirectories for reworked deploy, revert, and verify scripts. The value
comes from one of these options, searched in this order:

=over

=item * C<--dir reworked_dir=$reworked_dir>

=item * C<target.$name.reworked_dir>

=item * C<engine.$engine.reworked_dir>

=item * C<core.reworked_dir>

=item * C<$top_dir>

=back

=head3 C<reworked_deploy_dir>

  my $reworked_deploy_dir = $target->reworked_deploy_dir;

The path to the reworked deploy directory of the project. This directory
contains all of the reworked deploy scripts referenced by changes in the
C<plan_file>. The value comes from one of these options, searched in this
order:

=over

=item * C<--dir reworked_deploy_dir=$reworked_deploy_dir>

=item * C<target.$name.reworked_deploy_dir>

=item * C<engine.$engine.reworked_deploy_dir>

=item * C<core.reworked_deploy_dir>

=item * F<C<$reworked_dir/reworked_deploy>>

=back

=head3 C<reworked_revert_dir>

  my $reworked_revert_dir = $target->reworked_revert_dir;

The path to the reworked revert directory of the project. This directory
contains all of the reworked revert scripts referenced by changes the
C<plan_file>. The value comes from one of these options, searched in this
order:

=over

=item * C<--dir reworked_revert_dir=$reworked_revert_dir>

=item * C<target.$name.reworked_revert_dir>

=item * C<engine.$engine.reworked_revert_dir>

=item * C<core.reworked_revert_dir>

=item * F<C<$reworked_dir/reworked_revert>>

=back

=head3 C<reworked_verify_dir>

  my $reworked_verify_dir = $target->reworked_verify_dir;

The path to the reworked verify directory of the project. This directory
contains all of the reworked verify scripts referenced by changes in the
C<plan_file>. The value comes from one of these options, searched in this
order:

=over

=item * C<--dir reworked_verify_dir=$reworked_verify_dir>

=item * C<target.$name.reworked_verify_dir>

=item * C<engine.$engine.reworked_verify_dir>

=item * C<core.reworked_verify_dir>

=item * F<C<$reworked_dir/reworked_verify>>

=back

=head3 C<extension>

  my $extension = $target->extension;

The file name extension to append to change names to create script file names.
The value comes from one of these options, searched in this order:

=over

=item * C<--extension>

=item * C<target.$name.extension>

=item * C<engine.$engine.extension>

=item * C<core.extension>

=item * C<"sql">

=back

=head3 C<engine_key>

  my $key = $target->engine_key;

The key defining which engine to use. This value defines the class loaded by
C<engine>. Convenience method for C<< $target->uri->canonical_engine >>.

=head3 C<dsn>

  my $dsn = $target->dsn;

The DSN to use when connecting to the target via the DBI. Convenience method
for C<< $target->uri->dbi_dsn >>.

=head3 C<username>

  my $username = $target->username;

The username to use when connecting to the target via the DBI. Convenience
method for C<< $target->uri->user >>.

=head3 C<password>

  my $password = $target->password;

The password to use when connecting to the target via the DBI. Convenience
method for C<< $target->uri->password >>.

=head1 See Also

=over

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
