package App::Sqitch::Engine::pg;

use v5.10.1;
use Moose;
use utf8;
use Path::Class;
use DBI;
use Carp;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Step;
use namespace::autoclean;

extends 'App::Sqitch::Engine';

our $VERSION = '0.32';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->client
            || $sqitch->config->get( key => 'core.pg.client' )
            || 'psql' . ( $^O eq 'Win32' ? '.exe' : '' );
    },
);

has username => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->username || $sqitch->config->get( key => 'core.pg.username' );
    },
);

has actor => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub {
        $ENV{USER} || shift->username || $ENV{PGUSER};
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.pg.password' );
    },
);

has db_name => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        $sqitch->db_name || $sqitch->config->get( key => 'core.pg.db_name' );
    },
);

has destination => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        $self->db_name
            || $ENV{PGDATABASE}
            || $self->username
            || $ENV{PGUSER}
            || $ENV{USER};
    },
);

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->host || $sqitch->config->get( key => 'core.pg.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->port || $sqitch->config->get( key => 'core.pg.port' );
    },
);

has sqitch_schema => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.pg.sqitch_schema' )
            || 'sqitch';
    },
);

has psql => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my @ret  = ( $self->client );
        for my $spec (
            [ username => $self->username ],
            [ dbname   => $self->db_name  ],
            [ host     => $self->host     ],
            [ port     => $self->port     ],
            )
        {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        push @ret => (
            '--quiet',
            '--no-psqlrc',
            '--no-align',
            '--tuples-only',
            '--set' => 'ON_ERROR_ROLLBACK=1',
            '--set' => 'ON_ERROR_STOP=1',
            '--set' => 'sqitch_schema=' . $self->sqitch_schema,
        );
        return \@ret;
    },
);

has _dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        eval "require DBD::Pg";
        hurl pg => __ 'DBD::Pg module required to manage PostgreSQL' if $@;

        my $dsn = 'dbi:Pg:' . join ';' => map {
            "$_->[0]=$_->[1]"
        } grep { $_->[1] } (
            [ dbname   => $self->db_name  ],
            [ host     => $self->host     ],
            [ port     => $self->port     ],
        );

        DBI->connect($dsn, $self->username, $self->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            pg_enable_utf8    => 1,
            pg_server_prepare => 1,
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks         => {
                connected => sub {
                    shift->do('SET search_path = ?', undef, $self->sqitch_schema);
                    return;
                },
            },
        });
    }
);

sub config_vars {
    return (
        client        => 'any',
        username      => 'any',
        password      => 'any',
        db_name       => 'any',
        host          => 'any',
        port          => 'int',
        sqitch_schema => 'any',
    );
}

sub initialized {
    my $self = shift;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE FROM pg_catalog.pg_namespace WHERE nspname = ?
        )
    }, undef, $self->sqitch_schema)->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->sqitch_schema;
    hurl pg => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $schema
    ) if $self->initialized;

    my $file = file(__FILE__)->dir->file('pg.sql');
    $self->_run(
        '--file' => $file,
        '--set'  => "sqitch_schema=$schema",
    );

    $self->_dbh->do('SET search_path = ?', undef, $schema);
    return $self;
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--file' => $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub log_deploy_step {
    my ($self, $step) = @_;
    my $dbh = $self->_dbh;

    my ($id, $name, $req, $conf, $actor) = (
        $step->id,
        $step->format_name,
        [$step->requires],
        [$step->conflicts],
        $self->actor,
    );

    $dbh->do(q{
        INSERT INTO steps (step_id, step, requires, conflicts, deployed_by)
        VALUES (?, ?, ?, ?, ?)
    }, undef, $id, $name, $req, $conf, $actor);

    my @tags = $step->tags;
    if (@tags) {
        $dbh->do(
            'INSERT INTO tags (tag_id, tag, step_id, applied_by) VALUES '
            . join( ', ', ( q{(?, ?, ?, ?)} ) x @tags ),
            undef,
            map { ($_->id, $_->format_name, $id, $actor) } @tags
        );
        @tags = map { $_->format_name } @tags;
    }

    $dbh->do(q{
        INSERT INTO events (event, step_id, step, tags, logged_by)
        VALUES ('deploy', ?, ?, ?, ?);
    }, undef, $id, $name, \@tags, $actor);

    return $self;
}

sub log_fail_step {
    my ( $self, $step ) = @_;
    my $dbh  = $self->_dbh;
    my $tags = [ map { $_->format_name } $step->tags ];
    $dbh->do(q{
        INSERT INTO events (event, step_id, step, tags, logged_by)
        VALUES ('fail', ?, ?, ?, ?);
    }, undef, $step->id, $step->name, $tags, $self->actor);
    return $self;
}

sub log_revert_step {
    my ($self, $step) = @_;
    my $dbh = $self->_dbh;

    # Delete tags.
    my $del_tags = $dbh->selectcol_arrayref(
        'DELETE FROM tags WHERE step_id = ? RETURNING tag',
        undef, $step->id
    ) || [];

    # Delete the step record.
    $dbh->do(
        'DELETE FROM steps where step_id = ?',
        undef, $step->id
    );

    # Log it.
    $dbh->do(q{
        INSERT INTO events (event, step_id, step, tags, logged_by)
        VALUES ('revert', ?, ?, ?, ?);
    }, undef, $step->id, $step->name, $del_tags,  $self->actor);

    return $self;
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM tags
             WHERE tag_id = ?
        );
    }, undef, $tag->id)->[0];
}

sub is_deployed_step {
    my ( $self, $step ) = @_;
    $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM steps
             WHERE step_id = ?
        )
    }, undef, $step->id)->[0];
}

sub check_requires {
    my ( $self, $step ) = @_;

    # No need to check anything if there are no requirements.
    return unless $step->requires;

    return @{ $self->_dbh->selectcol_arrayref(q{
        SELECT required
          FROM UNNEST(?::text[]) required
         WHERE required <> ALL(ARRAY(SELECT step FROM steps))
         ORDER BY required;
    }, undef, [$step->requires]) || [] };
}

sub check_conflicts {
    my ( $self, $step ) = @_;

    # No need to check anything if there are no conflicts.
    return unless $step->conflicts;

    return @{ $self->_dbh->selectcol_arrayref(q{
        SELECT step
          FROM steps
         WHERE step = ANY(?)
         ORDER BY step
    }, undef, [$step->conflicts]) || [] };
}

sub _fetch_item {
    my ($self, $sql) = @_;
    return try {
        $self->_dbh->selectcol_arrayref($sql)->[0];
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
}

sub latest_step_id {
    my $self = shift;
    return try {
        $self->_dbh->selectcol_arrayref(q{
            SELECT step_id
              FROM steps
             ORDER BY deployed_at DESC
             LIMIT 1
        })->[0];
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
}

sub deployed_step_ids {
    return @{ shift->_dbh->selectcol_arrayref(qq{
        SELECT step_id AS id
          FROM steps
         ORDER BY deployed_at ASC
    }) };
}

sub deployed_step_ids_since {
    my ( $self, $step ) = @_;
    return @{ $self->_dbh->selectcol_arrayref(qq{
        SELECT step_id
          FROM steps
         WHERE deployed_at > (SELECT deployed_at FROM steps WHERE step_id = ?)
         ORDER BY deployed_at ASC
    }, undef, $step->id) };
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->run( $self->psql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->spool( $fh, $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->spool( $fh, $self->psql, @_ );
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine::pg - Sqitch PostgreSQL Engine

=head1 Synopsis

  my $pg = App::Sqitch::Engine->load( engine => 'pg' );

=head1 Description

App::Sqitch::Engine::pg provides the PostgreSQL storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::pg->config_vars;

Returns a hash of names and types to use for variables in the C<core.pg>
section of the a Sqitch configuration file. The variables and their types are:

  client        => 'any'
  username      => 'any'
  password      => 'any'
  db_name       => 'any'
  host          => 'any'
  port          => 'int'
  sqitch_schema => 'any'

=head2 Instance Methods

=head3 C<initialized>

  $pg->initialize unless $pg->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $pg->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema.

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
