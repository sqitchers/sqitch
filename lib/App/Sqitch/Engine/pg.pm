package App::Sqitch::Engine::pg;

use 5.010;
use Mouse;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.954';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.pg.client' )
            || 'psql' . ( $^O eq 'MSWin32' ? '.exe' : '' );
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
            || $self->sqitch->sysuser
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

        if (my %vars = $self->variables) {
            push @ret => map {; '--set', "$_=$vars{$_}" } sort keys %vars;
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

has dbh => (
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

sub _log_tags_param {
    [ map { $_->format_name } $_[1]->tags ];
}

sub _log_requires_param {
    [ map { $_->as_string } $_[1]->requires ];
}

sub _log_conflicts_param {
    [ map { $_->as_string } $_[1]->conflicts ];
}

sub _ts2char_format {
     q{to_char(%s AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _listagg_format { q{array_agg(%s)} }

sub _regex_op { '~' }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE FROM pg_catalog.pg_namespace WHERE nspname = ?
        )
    }, undef, $self->sqitch_schema)->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->sqitch_schema;
    hurl engine => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $schema
    ) if $self->initialized;

    my $file = file(__FILE__)->dir->file('pg.sql');
    $self->_run(
        '--file' => $file,
        '--set'  => "sqitch_schema=$schema",
    );

    $self->dbh->do('SET search_path = ?', undef, $schema);
    return $self;
}

sub register_project {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $plan   = $self->plan;
    my $proj   = $plan->project;
    my $uri    = $plan->uri;

    my $res = $self->dbh->selectcol_arrayref(
        'SELECT uri FROM projects WHERE project = ?',
        undef, $proj
    );

    if (@{ $res }) {
        # A project with that name is already registreed. Compare URIs.
        my $reg_uri = $res->[0];
        if ( defined $uri && !defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with NULL URI',
                project => $proj,
                uri     => $uri
            );
        } elsif ( !defined $uri && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" without URI: already exists with URI {uri}',
                project => $proj,
                uri     => $reg_uri
            );
        } elsif ( defined $uri && defined $reg_uri ) {
            hurl engine => __x(
                'Cannot register "{project}" with URI {uri}: already exists with URI {reg_uri}',
                project => $proj,
                uri     => $uri,
                reg_uri => $reg_uri,
            ) if $uri ne $reg_uri;
        } else {
            # Both are undef, so cool.
        }
    } else {
        # Does the URI already exist?
        my $res = $self->dbh->selectcol_arrayref(
            'SELECT project FROM projects WHERE uri = ?',
            undef, $uri
        );

        hurl engine => __x(
            'Cannot register "{project}" with URI {uri}: project "{reg_prog}" already using that URI',
            project => $proj,
            uri     => $uri,
            reg_proj => $res->[0],
        ) if @{ $res };

        # Insert the project.
        $self->dbh->do(q{
            INSERT INTO projects (project, uri, creator_name, creator_email)
            VALUES (?, ?, ?, ?)
        }, undef, $proj, $uri, $sqitch->user_name, $sqitch->user_email);
    }

    return $self;
}

sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');
    return $self;
}

sub finish_work {
    my $self = shift;
    $self->dbh->commit;
    return $self;
}

sub rollback_work {
    my $self = shift;
    $self->dbh->rollback;
    return $self;
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--file' => $file);
}

sub run_verify {
    my $self = shift;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    return $self->$meth('--file' => @_);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub log_deploy_change {
    my ($self, $change) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    my ($id, $name, $proj, $user, $email) = (
        $change->id,
        $change->format_name,
        $change->project,
        $sqitch->user_name,
        $sqitch->user_email
    );

    $dbh->do(q{
        INSERT INTO changes (
              change_id
            , change
            , project
            , note
            , committer_name
            , committer_email
            , planned_at
            , planner_name
            , planner_email
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    }, undef,
        $id,
        $name,
        $proj,
        $change->note,
        $user,
        $email,
        $change->timestamp->as_string(format => 'iso'),
        $change->planner_name,
        $change->planner_email,
    );

    if ( my @deps = $change->dependencies ) {
        $dbh->do(q{
            INSERT INTO dependencies(
                  change_id
                , type
                , dependency
                , dependency_id
           ) VALUES
        } . join( ', ', ( q{(?, ?, ?, ?)} ) x @deps ),
            undef,
            map { (
                $id,
                $_->type,
                $_->as_string,
                $_->resolved_id,
            ) } @deps
        );
    }

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

sub log_new_tags {
    my ( $self, $change ) = @_;
    my @tags   = $change->tags or return $self;
    my $sqitch = $self->sqitch;

    my ($id, $name, $proj, $user, $email) = (
        $change->id,
        $change->format_name,
        $change->project,
        $sqitch->user_name,
        $sqitch->user_email
    );

    $self->dbh->do(
        q{
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
            )
            SELECT tid, tg, proj, chid, n, name, email, at, pname, pemail FROM ( VALUES
        } . join( ",\n                ", ( q{(?, ?, ?, ?, ?, ?, ?, ?::timestamptz, ?, ?)} ) x @tags )
        . q{
            ) i(tid, tg, proj, chid, n, name, email, at, pname, pemail)
              LEFT JOIN tags ON i.tid = tags.tag_id
             WHERE tags.tag_id IS NULL
         },
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

    return $self;
}

sub log_fail_change {
    shift->_log_event( fail => shift );
}

sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->dbh;
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
        $change->note,
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
    my $dbh = $self->dbh;

    # Delete tags.
    my $del_tags = $dbh->selectcol_arrayref(
        'DELETE FROM tags WHERE change_id = ? RETURNING tag',
        undef, $change->id
    ) || [];

    # Retrieve dependencies.
    my ($req, $conf) = $dbh->selectrow_array(q{
        SELECT ARRAY(
            SELECT dependency
              FROM dependencies
             WHERE change_id = $1
               AND type = 'require'
        ), ARRAY(
            SELECT dependency
              FROM dependencies
             WHERE change_id = $1
               AND type = 'conflict'
        )
    }, undef, $change->id);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $change->id,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM tags
             WHERE tag_id = ?
        );
    }, undef, $tag->id)->[0];
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE
              FROM changes
             WHERE change_id = ?
        )
    }, undef, $change->id)->[0];
}

sub are_deployed_changes {
    my $self = shift;
    @{ $self->dbh->selectcol_arrayref(
        'SELECT change_id FROM changes WHERE change_id = ANY(?)',
        undef,
        [ map { $_->id } @_ ],
    ) };
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    return @{ $self->dbh->selectall_arrayref(q{
        SELECT c.change_id, c.project, c.change, (
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.project      = c.project
               AND c2.committed_at >= c.committed_at
             ORDER BY c2.committed_at
             LIMIT 1
        ) AS asof_tag
          FROM dependencies d
          JOIN changes c ON c.change_id = d.change_id
         WHERE d.dependency_id = ?
    }, { Slice => {} }, $change->id) };
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub change_id_for {
    my ( $self, %p) = @_;
    my $dbh = $self->dbh;

    if ( my $cid = $p{change_id} ) {
        # Find by ID.
        return $dbh->selectcol_arrayref(q{
            SELECT change_id
              FROM changes
             WHERE change_id = ?
        }, undef, $cid)->[0];
    }

    my $project = $p{project} || $self->plan->project;
    if ( my $change = $p{change} ) {
        if ( my $tag = $p{tag} ) {
            # Ther is nothing before the first tag.
            return undef if $tag eq 'ROOT' || $tag eq 'FIRST';

            # Find closest to the end for @HEAD.
            return $dbh->selectcol_arrayref(q{
                SELECT change_id
                  FROM changes
                 WHERE project = ?
                   AND change  = ?
                 ORDER BY committed_at DESC
                 LIMIT 1
            }, undef, $project, $change)->[0] if $tag eq 'HEAD' || $tag eq 'LAST';

            # Find by change name and following tag.
            return $dbh->selectcol_arrayref(q{
                SELECT changes.change_id
                  FROM changes
                  JOIN tags
                    ON changes.committed_at < tags.committed_at
                   AND changes.project = tags.project
                 WHERE changes.project = ?
                   AND changes.change  = ?
                   AND tags.tag        = ?
            }, undef, $project, $change, '@' . $tag)->[0];
        }

        # Find by change name. Fail if there are multiple.
        my $ids = $dbh->selectcol_arrayref(q{
            SELECT change_id
              FROM changes
             WHERE project = ?
               AND change  = ?
        }, undef, $project, $change);
        return $ids->[0] if @{ $ids } < 2;
        hurl engine => __x(
            'Key "{key}" matches multiple changes',
            key => $change,
        );
    }

    if ( my $tag = $p{tag} ) {
        # Just return the latest for @HEAD.
        return $self->_cid('DESC', 0, $project)
            if $tag eq 'HEAD' || $tag eq 'LAST';

        # Just return the earliest for @ROOT.
        return $self->_cid('ASC', 0, $project)
            if $tag eq 'ROOT' || $tag eq 'FIRST';

        # Find by tag name.
        return $dbh->selectcol_arrayref(q{
            SELECT change_id
              FROM tags
             WHERE project = ?
               AND tag     = ?
        }, undef, $project, '@' . $tag)->[0];
    }

    # We got nothin.
    return undef;
}

sub _fetch_item {
    my ($self, $sql) = @_;
    return try {
        $self->dbh->selectcol_arrayref($sql)->[0];
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;
    return try {
        $self->dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1
            OFFSET COALESCE(?::bigint, NULL)
        }, undef, $project || $self->plan->project, $offset)->[0];
    } catch {
        return if $DBI::state eq '42P01'; # undefined_table
        die $_;
    };
}

sub earliest_change_id {
    shift->_cid('ASC', @_);
}

sub latest_change_id {
    shift->_cid('DESC', @_);
}

sub load_change {
    my ( $self, $change_id ) = @_;
    my $tscol = _ts2char 'planned_at';
    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT change_id AS id, change AS name, project, note,
               $tscol AS timestamp, planner_name, planner_email,
               ARRAY(SELECT tag FROM tags WHERE change_id = changes.change_id) AS tags
          FROM changes
         WHERE change_id = ?
    }, undef, $change_id) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    return $change;
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
    my $tscol = _ts2char 'planned_at';
    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT change_id AS id, change AS name, project, note,
               $tscol AS timestamp, planner_name, planner_email,
               ARRAY(SELECT tag FROM tags WHERE change_id = changes.change_id) AS tags
          FROM changes
         WHERE project = ?
           AND committed_at $op (
               SELECT committed_at FROM changes WHERE change_id = ?
         )
         ORDER BY committed_at $dir
         OFFSET ?
    }, undef, $self->plan->project, $change_id, abs($offset) - 1) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    return $change;
}

sub deployed_changes {
    my $self = shift;
    my $tscol = _ts2char 'planned_at';
    return map {
        $_->{timestamp} = _dt $_->{timestamp}; $_
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT change_id AS id, change AS name, project, note,
               $tscol AS timestamp, planner_name, planner_email,
               ARRAY(SELECT tag FROM tags WHERE change_id = changes.change_id) AS tags
          FROM changes
         WHERE project = ?
         ORDER BY committed_at ASC
    }, { Slice => {} }, $self->plan->project) };
}

sub deployed_changes_since {
    my ( $self, $change ) = @_;
    my $tscol = _ts2char 'planned_at';
    return map {
        $_->{timestamp} = _dt $_->{timestamp}; $_
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT change_id AS id, change AS name, project, note,
               $tscol AS timestamp, planner_name, planner_email,
               ARRAY(SELECT tag FROM tags WHERE change_id = changes.change_id) AS tags
          FROM changes
         WHERE project = ?
           AND committed_at > (SELECT committed_at FROM changes WHERE change_id = ?)
         ORDER BY committed_at ASC
    }, { Slice => {} }, $self->plan->project, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT change || COALESCE((
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
               AND c2.project = c.project
             LIMIT 1
        ), '')
          FROM changes c
         WHERE change_id = ?
    }, undef, $change_id)->[0];
}

sub registered_projects {
    return @{ shift->dbh->selectcol_arrayref(
        'SELECT project FROM projects ORDER BY project'
    ) };
}

sub current_state {
    my ( $self, $project ) = @_;
    my $ddtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $state = $self->dbh->selectrow_hashref(qq{
        SELECT change_id
             , change
             , project
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
         WHERE project = ?
         ORDER BY changes.committed_at DESC
         LIMIT 1
    }, undef, $project // $self->plan->project ) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub current_changes {
    my ( $self, $project ) = @_;
    my $ddtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $sth   = $self->dbh->prepare(qq{
        SELECT change_id
             , change
             , committer_name
             , committer_email
             , $ddtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         WHERE project = ?
         ORDER BY changes.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub current_tags {
    my ( $self, $project ) = @_;
    my $tdtcol = _ts2char 'committed_at';
    my $pdtcol = _ts2char 'planned_at';
    my $sth   = $self->dbh->prepare(qq{
        SELECT tag_id
             , tag
             , committer_name
             , committer_email
             , $tdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM tags
         WHERE project = ?
         ORDER BY tags.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
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
    my $sth = $self->dbh->prepare(qq{
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

# This method only required by pg, as no other engines existed when change and
# tag IDs changed.
sub _update_ids {
    my $self = shift;
    my $plan = $self->plan;
    my $proj = $plan->project;
    my $maxi = 0;

    $self->SUPER::_update_ids;
    my $dbh = $self->dbh;
    $dbh->begin_work;
    try {
        # First, we have to recreate the FK constraint on dependencies.
        $dbh->do(q{
            ALTER TABLE dependencies
             DROP CONSTRAINT dependencies_change_id_fkey,
              ADD FOREIGN KEY (change_id) REFERENCES changes (change_id)
                  ON UPDATE CASCADE ON DELETE CASCADE;
        });

        my $sth = $dbh->prepare(q{
            SELECT change_id, change, committed_at
              FROM changes
             WHERE project = ?
        });
        my $atag_sth = $dbh->prepare(q{
            SELECT tag
              FROM tags
             WHERE project = ?
               AND committed_at < ?
             LIMIT 1
        });
        my $btag_sth = $dbh->prepare(q{
            SELECT tag
              FROM tags
             WHERE project = ?
               AND committed_at >= ?
             LIMIT 1
        });
        my $upd = $dbh->prepare(
            'UPDATE changes SET change_id = ? WHERE change_id = ?'
        );

        $sth->execute($proj);
        $sth->bind_columns(\my ($old_id, $name, $date));

        while ($sth->fetch) {
            # Try to find it in the plan by the old ID.
            if (my $idx = $plan->index_of($old_id)) {
                $upd->execute($plan->change_at($idx)->id, $old_id);
                $maxi = $idx if $idx > $maxi;
                next;
            }

            # Try to find it by the tag that precedes it.
            if (my $tag = $dbh->selectcol_arrayref($atag_sth, undef, $proj, $date)->[0]) {
                if (my $idx = $plan->first_index_of($name, $tag)) {
                    $upd->execute($plan->change_at($idx)->id, $old_id);
                    $maxi = $idx if $idx > $maxi;
                    next;
                }
            }

            # Try to find it by the tag that succeeds it.
            if (my $tag = $dbh->selectcol_arrayref($btag_sth, undef, $proj, $date)->[0]) {
                if (my $change = $plan->find($name . $tag)) {
                    $upd->execute($change->id, $old_id);
                    my $idx = $plan->index_of($change->id);
                    $maxi = $idx if $idx > $maxi;
                    next;
                }
            }

            # Try to find it by name. Throws an exception if there is more than one.
            if (my $change = $plan->get($name)) {
                $upd->execute($change->id, $old_id);
                my $idx = $plan->index_of($change->id);
                $maxi = $idx if $idx > $maxi;
                next;
            }

            # If we get here, we're fucked.
            hurl engine => "Unable to find $name ($old_id) in the plan; update failed";
        }

        # Now update tags.
        $sth = $dbh->prepare('SELECT tag_id, tag FROM tags WHERE project = ?');
        $upd = $dbh->prepare('UPDATE tags SET tag_id = ? WHERE tag_id = ?');
        $sth->execute($proj);
        $sth->bind_columns(\($old_id, $name));
        while ($sth->fetch) {
            my $change = $plan->find($old_id) || $plan->find($name)
                or hurl engine => "Unable to find $name ($old_id) in the plan; update failed";
            my $tag = first { $_->old_id eq $old_id } $change->tags;
            $tag ||= first { $_->format_name eq $name } $change->tags;
            hurl engine => "Unable to find $name ($old_id) in the plan; update failed"
                unless $tag;
            $upd->execute($tag->id, $old_id);
        }

        # Success!
        $dbh->commit;
    } catch {
        $dbh->rollback;
        die $_;
    };
    return $maxi;
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->run( $self->psql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->capture( $self->psql, @_ );
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
no Mouse;

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

Copyright (c) 2012-2013 iovation Inc.

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
