package App::Sqitch::Engine::pg;

use v5.10.1;
use Moose;
use utf8;
use Path::Class;
use DBI;
use Carp;
use Try::Tiny;
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
        die "DBD::Pg module required to manage PostgreSQL\n"
            if $@;

        my $dsn = 'dbi:Pg:' . join ';' => map {
            "$_->[0]=$_->[1]"
        } grep { $_->[1] } (
            [ dbname   => $self->db_name  ],
            [ host     => $self->host     ],
            [ port     => $self->port     ],
        );

        DBI->connect($dsn, $self->username, $self->password, {
            PrintError        => 0,
            RaiseError        => 1,
            AutoCommit        => 1,
            pg_enable_utf8    => 1,
            pg_server_prepare => 1,
            # HandleError       => sub {
            #     my ($err, $dbh) = @_;
            #     $dbh->rollback unless $dbh->{AutoCommit};
            #     die $err;
            # },
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
    die qq{Sqitch schema "$schema" already exists\n} if $self->initialized;

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

sub _begin_tag {
    my $self = shift;
    my $dbh  = $self->_dbh;

    # Start transactiojn and lock tags to allow one tag change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE tags IN EXCLUSIVE MODE');
    return $dbh;
}

sub begin_deploy_tag {
    my ( $self, $tag ) = @_;
    my $dbh = $self->_begin_tag;

    $dbh->do(
        'INSERT INTO tags (applied_by) VALUES(?)',
        undef, $self->actor
    );

    $dbh->do( q{
        INSERT INTO tag_names (tag_id, tag_name)
        SELECT lastval(), t FROM UNNEST(?::text[]) AS t
    }, undef, [ $tag->names ] );

    return $self;
}

sub begin_revert_tag {
    my ( $self, $tag ) = @_;
    $self->_begin_tag;
    return $self;
}

sub commit_deploy_tag {
    my ( $self, $tag ) = @_;
    my $dbh = $self->_dbh;
    croak(
        "Cannot call commit_deploy_tag() without first calling begin_deploy_tag()"
    ) if $dbh->{AutoCommit};
    $dbh->do(q{
        INSERT INTO events (event, tags, logged_by)
        VALUES ('apply', ?, ?);
    }, undef, [$tag->names], $self->actor);
    $dbh->commit;
}

sub _revert_tag {
    my ( $self, $tag, $dbh ) = @_;
    $dbh->do(q{
        DELETE FROM tags WHERE tag_id IN (
            SELECT tag_id
              FROM tag_names
             WHERE tag_name = ANY(?)
        );
    }, undef, [$tag->names]);
    $dbh->commit;
}

sub rollback_deploy_tag {
    my ( $self, $tag ) = @_;
    my $dbh = $self->_dbh;
    croak(
        "Cannot call rollback_deploy_tag() without first calling begin_deploy_tag()"
    ) if $dbh->{AutoCommit};
    $self->_revert_tag( $tag, $dbh );
}

sub commit_revert_tag {
    my ( $self, $tag ) = @_;
    my $dbh = $self->_dbh;
    croak(
        "Cannot call commit_revert_tag() without first calling begin_revert_tag()"
    ) if $dbh->{AutoCommit};
    $self->_revert_tag( $tag, $dbh );
    $dbh->do(q{
        INSERT INTO events (event, tags, logged_by)
        VALUES ('remove', ?, ?);
    }, undef, [$tag->names], $self->actor);
}

sub log_deploy_step {
    my ($self, $step) = @_;
    my $dbh = $self->_dbh;
    croak(
        'Cannot deploy a step without first calling begin_deploy_tag()'
    ) if $dbh->{AutoCommit};

    my ($name, $req, $conf, $actor) = (
        $step->name,
        [$step->requires],
        [$step->conflicts],
        $self->actor,
    );

    $dbh->do(q{
        INSERT INTO steps (step, tag_id, requires, conflicts, deployed_by)
        VALUES (?, lastval(), ?, ?, ?)
    }, undef, $name, $req, $conf, $actor);
    $dbh->do(q{
        INSERT INTO events (event, step, tags, logged_by)
        VALUES ('deploy', ?, ?, ?);
    }, undef, $name, [$step->tag->names], $actor);

    return $self;
}

sub log_fail_step {
    my ( $self, $step ) = @_;
    my $dbh  = $self->_dbh;
    croak(
        'Cannot log a step failure first calling begin_deploy_tag()'
    ) if $dbh->{AutoCommit};
    $dbh->do(q{
        INSERT INTO events (event, step, tags, logged_by)
        VALUES ('fail', ?, ?, ?);
    }, undef, $step->name, [$step->tag->names], $self->actor);
    return $self;
}

sub log_revert_step {
    my ($self, $step) = @_;
    my $dbh = $self->_dbh;
    croak(
        'Cannot revert a step without first calling begin_revert_tag()'
    ) if $dbh->{AutoCommit};

    $dbh->do(q{
        INSERT INTO events (event, step, logged_by, tags)
        SELECT 'revert', step, $1, ARRAY(
            SELECT tag_name FROM tag_names WHERE tag_id = steps.tag_id
        ) FROM steps
         WHERE step = $2
    }, undef, $self->actor, $step->name);

    $dbh->do(q{
        DELETE FROM steps where step = ? AND tag_id = (
            SELECT tag_id FROM tag_names WHERE tag_name = ?
        );
    }, undef, $step->name, ($step->tag->names)[0]);

    return $self;
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM tag_names
             WHERE tag_name = ANY(?)
        );
    }, undef, [$tag->names])->[0];
}

sub is_deployed_step {
    my ( $self, $step ) = @_;
    $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM steps
             WHERE step = ?
        )
    }, undef, $step->name)->[0];
}

sub deployed_steps_for {
    my ( $self, $tag ) = @_;
    my $dbh = $self->_dbh;

    # Find all steps installed before this tag.
    my %seen = map { $_ => 1 } @{
        $dbh->selectcol_arrayref(q{
            SELECT step
              FROM steps
             WHERE deployed_at < (
                SELECT MIN(deployed_at)
                  FROM steps
                  JOIN tag_names ON steps.tag_id = tag_names.tag_id
                 WHERE tag_name = ANY(?)
             )
        }, undef, [$tag->names]) || []
    };

    return @{ $tag->plan->sort_steps(\%seen, map {
        chomp;
        App::Sqitch::Plan::Step->new(name => $_, tag => $tag)
    } @{ $dbh->selectcol_arrayref(q{
        SELECT DISTINCT step
          FROM steps
          JOIN tag_names ON steps.tag_id = tag_names.tag_id
         WHERE tag_name = ANY(?)
    }, undef, [$tag->names]) || [] } ) };
}

sub check_conflicts {
    my ( $self, $step ) = @_;

    # No need to check anything if there are no conflicts.
    return unless $step->conflicts;

    return @{ $self->_dbh->selectcol_arrayref(q{
        SELECT step
          FROM steps
         WHERE step = ANY(?)
    }, undef, [$step->conflicts]) || [] };
}

sub check_requires {
    my ( $self, $step ) = @_;

    # No need to check anything if there are no requirements.
    return unless $step->requires;

    return @{ $self->_dbh->selectcol_arrayref(q{
        SELECT required
          FROM UNNEST(?::text[]) required
         WHERE required <> ALL(ARRAY(SELECT step FROM steps));
    }, undef, [$step->requires]) || [] };
}

sub current_tag_name {
    my $dbh = shift->_dbh;
    return try {
        $dbh->selectrow_array(q{
            SELECT tag_name
              FROM tag_names
             WHERE tag_id = (
                 SELECT tag_id
                   FROM tags
                  ORDER BY applied_at DESC
                  LIMIT 1
              )
             LIMIT 1;
        });
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
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
