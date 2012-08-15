package App::Sqitch::Engine::pg;

use v5.10.1;
use Moose;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use namespace::autoclean;

extends 'App::Sqitch::Engine';

our $VERSION = '0.83';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
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
        $sqitch->db_username || $sqitch->config->get( key => 'core.pg.username' );
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
        $sqitch->db_host || $sqitch->config->get( key => 'core.pg.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_port || $sqitch->config->get( key => 'core.pg.port' );
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

sub register_project {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $plan   = $sqitch->plan;
    return try {
        $self->_dbh->do(q{
            INSERT INTO projects (project, uri, creator_name, creator_email)
            VALUES (?, ?, ?, ?)
        }, undef, $plan->project, $plan->uri, $sqitch->user_name, $sqitch->user_email);
        return $self;
    } catch {
        return $self if $DBI::state eq '23505'; # unique_violation
        die $_;
    };
}

sub begin_work {
    my $self = shift;
    my $dbh = $self->_dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');
    return $self;
}

sub finish_work {
    my $self = shift;
    $self->_dbh->commit;
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

sub log_deploy_change {
    my ($self, $change) = @_;
    my $dbh    = $self->_dbh;
    my $sqitch = $self->sqitch;

    my ($id, $name, $proj, $req, $conf, $user, $email) = (
        $change->id,
        $change->format_name,
        $change->project,
        [map { $_->as_string } $change->requires],
        [map { $_->as_string } $change->conflicts],
        $sqitch->user_name,
        $sqitch->user_email
    );

    $dbh->do(q{
        INSERT INTO changes (
              change_id
            , change
            , project
            , note
            , requires
            , conflicts
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    }, undef,
        $id,
        $name,
        $proj,
        $change->note,
        $req,
        $conf,
        $user,
        $email,
        $change->timestamp->as_string(format => 'iso'),
        $change->planner_name,
        $change->planner_email,
    );

    if ( my @tags = $change->tags ) {
        $dbh->do(q{
            INSERT INTO tags (
                  tag_id
                , tag
                , project
                , change_id
                , note
                , committer_name
                , committer_email
                , planned_at
                , planner_name
                , planner_email
           ) VALUES
        } . join( ', ', ( q{(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)} ) x @tags ),
            undef,
            map { (
                $_->id,
                $_->format_name,
                $proj,
                $id,
                $_->note,
                $user,
                $email,
                $_->timestamp->as_string(format => 'iso'),
                $_->planner_name,
                $_->planner_email,
            ) } @tags
        );
    }

    return $self->_log_event( deploy => $change );
}

sub log_fail_change {
    shift->_log_event( fail => shift );
}

sub _log_event {
    my ( $self, $event, $change, $tags, $note, $requires, $conflicts) = @_;
    my $dbh    = $self->_dbh;
    my $sqitch = $self->sqitch;

    $dbh->do(q{
        INSERT INTO events (
              event
            , change_id
            , change
            , project
            , note
            , tags
            , requires
            , conflicts
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $note      // $change->note,
        $tags      || [ map { $_->format_name } $change->tags ],
        $requires  || [ map { $_->as_string } $change->requires ],
        $conflicts || [ map { $_->as_string } $change->conflicts ],
        $sqitch->user_name,
        $sqitch->user_email,
        $change->timestamp->as_string(format => 'iso'),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->_dbh;

    # Delete tags.
    my $del_tags = $dbh->selectcol_arrayref(
        'DELETE FROM tags WHERE change_id = ? RETURNING tag',
        undef, $change->id
    ) || [];

    # Delete the change record.
    my ($req, $conf, $note) = $dbh->selectrow_array(q{
        DELETE FROM changes where change_id = ?
        RETURNING requires, conflicts, note
    }, undef, $change->id);

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $note, $req, $conf );
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

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM changes
             WHERE change_id = ?
        )
    }, undef, $change->id)->[0];
}

sub is_satisfied_depend {
    my ( $self, $dep ) = @_;
    my $dbh  = $self->_dbh;

    if ( defined ( my $cid = $dep->id ) ) {
        # Find by ID.
        return $dbh->selectcol_arrayref(q{
            SELECT EXISTS(
                SELECT TRUE
                  FROM changes
                 WHERE change_id = ?
            )
         }, undef, $cid)->[0];
    }

    if ( defined ( my $change = $dep->change ) ) {
        if ( defined ( my $tag = $dep->tag ) ) {
            # Find by change name and following tag.
            return $dbh->selectcol_arrayref(q{
                SELECT EXISTS(
                    SELECT TRUE
                      FROM changes
                      JOIN tags
                        ON changes.committed_at < tags.committed_at
                       AND changes.project = tags.project
                     WHERE changes.project = ?
                       AND changes.change  = ?
                       AND tags.tag        = ?
                )
            }, undef, $dep->project, $change, '@' . $tag)->[0];
        }

        # Find by change name.
        return $dbh->selectcol_arrayref(q{
            SELECT EXISTS(
                SELECT TRUE
                  FROM changes
                 WHERE project = ?
                   AND change  = ?
            )
        }, undef, $dep->project, $change)->[0];
    }

    if ( defined ( my $tag = $dep->tag ) ) {
        # Find by tag name.
        return $dbh->selectcol_arrayref(q{
            SELECT EXISTS(
                SELECT TRUE
                  FROM tags
                 WHERE project = ?
                   AND tag     = ?
            )
        }, undef, $dep->project, '@' . $tag)->[0];
    }

    hurl pg => __x(
        'Invalid dependency: {dependency}',
        $dep->as_string,
    );
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

sub latest_change_id {
    my $self = shift;
    return try {
        $self->_dbh->selectcol_arrayref(q{
            SELECT change_id
              FROM changes
             ORDER BY committed_at DESC
             LIMIT 1
        })->[0];
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
}

sub deployed_change_ids {
    return @{ shift->_dbh->selectcol_arrayref(qq{
        SELECT change_id AS id
          FROM changes
         ORDER BY committed_at ASC
    }) };
}

sub deployed_change_ids_since {
    my ( $self, $change ) = @_;
    return @{ $self->_dbh->selectcol_arrayref(qq{
        SELECT change_id
          FROM changes
         WHERE committed_at > (SELECT committed_at FROM changes WHERE change_id = ?)
         ORDER BY committed_at ASC
    }, undef, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT change || COALESCE((
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
             LIMIT 1
        ), '')
          FROM changes c
         WHERE change_id = ?
    }, undef, $change_id)->[0];
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub current_state {
    my $self  = shift;
    my $ddtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $state = $self->_dbh->selectrow_hashref(qq{
        SELECT change_id
             , change
             , note
             , committer_name
             , committer_email
             , $ddtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
             , ARRAY(
                 SELECT tag
                   FROM tags
                  WHERE change_id = changes.change_id
                  ORDER BY committed_at
             ) AS tags
          FROM changes
         ORDER BY changes.committed_at DESC
         LIMIT 1
    }) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub current_changes {
    my $self  = shift;
    my $ddtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $sth   = $self->_dbh->prepare(qq{
        SELECT change_id
             , change
             , committer_name
             , committer_email
             , $ddtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         ORDER BY changes.committed_at DESC
    });
    $sth->execute;
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub current_tags {
    my $self  = shift;
    my $tdtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $sth   = $self->_dbh->prepare(qq{
        SELECT tag_id
             , tag
             , committer_name
             , committer_email
             , $tdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM tags
         ORDER BY tags.committed_at DESC
    });
    $sth->execute;
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub search_events {
    my ( $self, %p ) = @_;

    # Determine order direction.
    my $dir = 'DESC';
    if (my $d = delete $p{direction}) {
        $dir = $d =~ /^ASC/i  ? 'ASC'
             : $d =~ /^DESC/i ? 'DESC'
             : hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Limit with regular expressions?
    my (@wheres, @params);
    for my $spec (
        [ committer => 'committer_name' ],
        [ planner   => 'planner_name'   ],
        [ change    => 'change'         ],
        [ project   => 'project'        ],
    ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "$spec->[1] ~ ?";
        push @params => $regex;
    }

    # Match events?
    if (my $e = delete $p{event} ) {
        push @wheres => 'event = ANY(?)';
        push @params => $e;
    }

    # Assemble the where clause.
    my $where = @wheres
        ? "\n         WHERE " . join( "\n               ", @wheres )
        : '';

    # Handle remaining parameters.
    push @params, delete @p{ qw(limit offset) };
    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $sth = $self->_dbh->prepare(qq{
        SELECT event
             , project
             , change_id
             , change
             , note
             , requires
             , conflicts
             , tags
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM events$where
         ORDER BY events.committed_at $dir
         LIMIT COALESCE(?::INT, NULL)
        OFFSET COALESCE(?::INT, NULL)
    });
    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
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
