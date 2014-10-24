package App::Sqitch::Target;

use 5.010;
use Moo;
use strict;
use warnings;
use App::Sqitch::Types qw(Maybe URIDB Str Dir Engine Sqitch File Plan);
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use Path::Class qw(dir file);
use namespace::autoclean;

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);
sub target { shift->name }

has uri  => (
    is   => 'ro',
    isa  => URIDB,
    required => 1,
    handles => {
        engine_key => 'canonical_engine',
        dsn        => 'dbi_dsn',
        username   => 'user',
        password   => 'password',
    },
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

sub _fetch {
    my ($self, $key) = @_;
    my $sqitch = $self->sqitch;
    if (my $val = $sqitch->options->{$key}) {
        return $val;
    }

    my $config = $sqitch->config;
    return $config->get( key => "target." . $self->name . ".$key" )
        || $config->get( key => "core." .($self->engine_key || '') . ".$key")
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
        # XXX Update to reference target.
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

has deploy_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('deploy_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('deploy')->cleanup;
    },
);

has revert_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('revert_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('revert')->cleanup;
    },
);

has verify_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('verify_dir') ) {
            return dir $dir;
        }
        $self->top_dir->subdir('verify')->cleanup;
    },
);

has extension => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        shift->_fetch('extension') || 'sql';
    },
);

# If no name:
#   a. use URI for name; or
#   b. Look for core.$engine.target.
# If no URI:
#   a. Use name if it exists and contains a colon; or
#   b. If name exists: look for target.$name.uri or die; or
#   c. Default to "db:$engine:"
# If still no name, use URI.

# Need to move command-line options into a hash, remove accessors in App::Sqitch.
# Remove attributes here from App::Sqitch and Engine.

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    my $sqitch = $p->{sqitch} or return $p;

    # The name defaults to the URI, if we have one.
    if (my $uri = $p->{uri}) {
        if (!$p->{name}) {
            # Set the URI as the name, sans password.
            if ($uri->password) {
                $uri = $uri->clone;
                $uri->password(undef);
            }
            $p->{name} = $uri->as_string;

        }
        return $p;
    }

    my ($uri, $ekey);
    my $name = $p->{name};

    # If no name, try to find one.
    if (!$name) {
        # Look for an engine key.
        $ekey = $sqitch->options->{engine} || $sqitch->config->get(
            key => 'core.engine'
        ) or hurl target => __(
            'No engine specified; use --engine or set core.engine'
        );

        # Find the name in the engine config, or fall back on a simple URI.
        $uri = $sqitch->config->get(key => "core.$ekey.target") || "db:$ekey:";
        $p->{name} = $name = $uri;
    }

    # Now we should have a name. What is it?
    if ($name =~ /:/) {
        # The name is a URI.
        require URI::db;
        $uri = URI::db->new($name);
        $name = $p->{name} = undef;
    } else {
        # Well then, there had better be a config with a URI.
        $uri = $sqitch->config->get( key => "target.$name.uri" ) or do {
            # Die on no section or no URI.
            hurl target => __x(
                'Cannot find target "{target}"',
                target => $name
            ) unless %{ $sqitch->config->get_section(
                section => "target.$name"
            ) };
            hurl target => __x(
                'No URI associated with target "{target}"',
                target => $name,
            );
        };
    }

    # Instantiate the URI.
    require URI::db;
    $uri    = $p->{uri} = URI::db->new( $uri );
    $ekey ||= $uri->canonical_engine or hurl target => __x(
        'No engine specified by URI {uri}; URI must start with "db:$engine:"',
        uri => $uri->as_string,
    );

    # Override parts with deprecated command-line options and config.
    my $opts   = $sqitch->options;
    my $config = $sqitch->config->get_section(section => "core.$ekey") || {};

    my @deprecated;
    if (my $host = $opts->{db_host}) {
        push @deprecated => '--db-host';
        $uri->host($host);
    } elsif ($host = $config->{host}) {
        push @deprecated => "core.$ekey.host";
        $uri->host($host);
    }

    if (my $port = $opts->{db_port}) {
        push @deprecated => '--db-port';
        $uri->port($port);
    } elsif ($port = $config->{port}) {
        push @deprecated => "core.$ekey.port";
        $uri->port($port);
    }

    if (my $user = $opts->{db_username}) {
        push @deprecated => '--db-username';
        $uri->user($user);
    } elsif ($user = $config->{username}) {
        push @deprecated => "core.$ekey.username";
        $uri->user($user);
    }

    if (my $pass = $config->{password}) {
        push @deprecated => "core.$ekey.password";
        $uri->password($pass);
    }

    if (my $db = $opts->{db_name}) {
        push @deprecated => '--db-name';
        $uri->dbname($db);
    } elsif ($db = $config->{db_name}) {
        push @deprecated => "core.$ekey.db_name";
        $uri->dbname($db);
    }

    if (@deprecated) {
        $sqitch->warn(__nx(
            'Option {options} deprecated and will be removed in 1.0; use URI {uri} instead',
            'Options {options} deprecated and will be removed in 1.0; use URI {uri} instead',
            scalar @deprecated,
            options => join(', ', @deprecated),
            uri     => $uri->as_string,
        ));
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

=head3 C<new>

  my $target = App::Sqitch::Target->new( sqitch => $sqitch );

Instantiates and returns an App::Sqitch::Target object. The most important
parameters are C<sqitch>, C<name> and C<uri>. The constructor tries really hard
to figure out the proper name and URI during construction by taking the
following steps:

XXX 

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $target->sqitch;

Returns the L<App::Sqitch> object that instantiated the target.

=head3 C<name>

=head3 C<target>

  my $name = $target->name;
  $name = $target->target;



=head3 C<uri>

  my $uri = $target->uri;



=head3 C<engine>

  my $engine = $target->engine;



=head3 C<registry>

  my $registry = $target->registry;



=head3 C<client>

  my $client = $target->client;



=head3 C<plan_file>

  my $plan_file = $target->plan_file;



=head3 C<top_dir>

  my $top_dir = $target->top_dir;



=head3 C<deploy_dir>

  my $deploy_dir = $target->deploy_dir;



=head3 C<revert_dir>

  my $revert_dir = $target->revert_dir;



=head3 C<verify_dir>

  my $verify_dir = $target->verify_dir;



=head3 C<extension>

  my $extension = $target->extension;



=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2014 iovation Inc.

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
