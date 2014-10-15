package App::Sqitch::Target;

use 5.010;
use Moo;
use strict;
use warnings;
use App::Sqitch::Types qw(Maybe URIDB Str Dir Engine);
use Path::Class qw(dir);
use namespace::autoclean;

has name => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has uri  => (
    is   => 'ro',
    isa  => URIDB,
    required => 1,
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
        my $sqitch = $self->sqitch;
        require App::Sqitch::Engine;
        App::Sqitch::Engine->load({
            sqitch => $sqitch,
            engine => $sqitch->_engine || $self->uri->canonical_engine,
        });
    },
);

has registry => (
    is  => 'ro',
    isa => Str,
    lazy => 1,
    default => sub {
        my $self   = shift;
        my $engine = $self->engine;
        my $ekey   = $engine->key;
        return $self->sqitch->config->get(
            key => "core.$ekey.registry"
        ) || $engine->default_registry;
    },
);

has client => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $self   = shift;
        my $engine = $self->engine;
        my $ekey   = $engine->key;
        return $self->sqitch->config->get(
            key => "core.$ekey.registry"
        ) or do {
            my $client = $self->default_client;
            return $client if $^O ne 'MSWin32';
            return $client if $client =~ /[.](?:exe|bat)$/;
            return $client . '.exe';
        };
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
        || $config->get( key => "engine." . $self->engine->key . ".$key")
        || $config->get( key => "core.$key");
}

has plan_file => (
    is       => 'ro',
    isa      => File,
    lazy     => 1,
    default => sub {
        my $self = shift;
        if (my $f = shift->_fetch('plan_file') {
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
        # XXX Modify to use target.
        App::Sqitch::Plan->new( sqitch => shift );
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
        if ( my $dir = $self->_fetch('deploy_dir');
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
        if ( my $dir = $self->_fetch('revert_dir');
            return dir $dir;
        }
        $self->top_dir->subdir('deploy')->cleanup;
    },
);

has verify_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        my $self = shift;
        if ( my $dir = $self->_fetch('verify_dir');
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
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    my $sqitch = $p->{sqitch} or return $p;

    # The name defaults to the URI, if we have one.
    if (my $uri = $p->{uri}) {
        $p->{name} ||= "$uri";
        return $p;
    }

    # If no name, try to find the default.
    my $uri;
    my $ekey = $sqitch->_engine;
    my $name = $p->{name} ||= $sqitch->config->get(
        key => "core.$engine.target"
    );

    # If no URI, we have to find one.
    if (!$name) {
        # Fall back on the default.
        $p->{name} = $uri = "db:$ekey";
    } elsif ($name =~ /:/) {
        # The name is a URI.
        $uri = URI::db->new($name);
    } else {
        # Well then, we have a whole config to load up.
        my $config = $sqitch->config->get_section(
            section => "target.$t"
        ) or hurl target => __x(
            'Cannot find target "{target}"',
            target => $name
        );

        # There had best be a URI.
        $uri = $config->{uri} or hurl target => __(
            'No URI associated with target "{target}"',
            target => $name,
        );
    }

    # Instantiate the URI and override parts with command-line options.
    # TODO: Deprecate these.
    $uri = $p->{uri} = URI::db->new( $uri );

    # Override parts with command-line options (deprecate?)
    if (my $host = $sqitch->db_host) {
        $uri->host($host);
    }

    if (my $port = $sqitch->db_port) {
        $uri->port($port);
    }

    if (my $user = $sqitch->db_username) {
        $uri->user($user);
    }

    if (my $db = $sqitch->db_name) {
        $uri->dbname($db);
    }

    return $p;
}

1;
__END__
