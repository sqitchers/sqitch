package App::Sqitch::Role::DBIEngine;

use 5.010;
use strict;
use warnings;
use utf8;
use DBI;
use Moo::Role;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

our $VERSION = '0.9998';

requires 'dbh';
requires 'sqitch';
requires 'plan';
requires '_regex_op';
requires '_ts2char_format';
requires '_char2ts';
requires '_listagg_format';
requires '_no_table_error';
requires '_handle_lookup_index';

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _log_tags_param {
    join ' ' => map { $_->format_name } $_[1]->tags;
}

sub _log_requires_param {
    join ',' => map { $_->as_string } $_[1]->requires;
}

sub _log_conflicts_param {
    join ',' => map { $_->as_string } $_[1]->conflicts;
}

sub _ts_default { 'DEFAULT' }

sub _can_limit { 1 }
sub _limit_default { undef }

sub _simple_from { '' }

sub _quote_idents { shift; @_ }

sub _in_expr {
    my ($self, $vals) = @_;
    my $in = sprintf 'IN (%s)', join ', ', ('?') x @{ $vals };
    return $in, @{ $vals };
}

sub _register_release {
    my $self    = shift;
    my $version = shift || $self->registry_release;
    my $sqitch  = $self->sqitch;
    my $ts      = $self->_ts_default;

    $self->begin_work;
    $self->dbh->do(qq{
        INSERT INTO releases (version, installed_at, installer_name, installer_email)
        VALUES (?, $ts, ?, ?)
    }, undef, $version, $sqitch->user_name, $sqitch->user_email);
    $self->finish_work;
    return $self;
}

sub _version_query { 'SELECT MAX(version) FROM releases' }

sub registry_version {
    my $self = shift;
    try {
        $self->dbh->selectcol_arrayref($self->_version_query)->[0];
    } catch {
        return 0 if $self->_no_table_error;
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
            OFFSET COALESCE(?, 0)
        }, undef, $project || $self->plan->project, $offset)->[0];
    } catch {
        return if $self->_no_table_error && !$self->initialized;
        die $_;
    };
}

sub earliest_change_id {
    shift->_cid('ASC', @_);
}

sub latest_change_id {
    shift->_cid('DESC', @_);
}

sub _select_state {
    my ( $self, $project, $with_hash ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $hshcol = $with_hash ? "c.script_hash\n                 , " : '';
    my $dbh    = $self->dbh;
    $dbh->selectrow_hashref(qq{
        SELECT c.change_id
             , ${hshcol}c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , $cdtcol AS committed_at
             , c.planner_name
             , c.planner_email
             , $pdtcol AS planned_at
             , $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
         GROUP BY c.change_id
             , ${hshcol}c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , c.committed_at
             , c.planner_name
             , c.planner_email
             , c.planned_at
         ORDER BY c.committed_at DESC
         LIMIT 1
    }, undef, $project // $self->plan->project );
}

sub current_state {
    my ( $self, $project ) = @_;
    my $state  = try {
        $self->_select_state($project, 1)
    } catch {
        return if $self->_no_table_error && !$self->initialized;
        return $self->_select_state($project, 0) if $self->_no_column_error;
        die $_;
    } or return undef;

    unless (ref $state->{tags}) {
        $state->{tags} = $state->{tags} ? [ split / / => $state->{tags} ] : [];
    }
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub current_changes {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $sth    = $self->dbh->prepare(qq{
        SELECT c.change_id
             , c.script_hash
             , c.change
             , c.committer_name
             , c.committer_email
             , $cdtcol AS committed_at
             , c.planner_name
             , c.planner_email
             , $pdtcol AS planned_at
          FROM changes c
         WHERE project = ?
         ORDER BY c.committed_at DESC
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
    my $cdtcol = sprintf $self->_ts2char_format, 'committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'planned_at';
    my $sth    = $self->dbh->prepare(qq{
        SELECT tag_id
             , tag
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
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
    my $op = $self->_regex_op;
    for my $spec (
        [ committer => 'e.committer_name' ],
        [ planner   => 'e.planner_name'   ],
        [ change    => 'e.change'         ],
        [ project   => 'e.project'        ],
    ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "$spec->[1] $op ?";
        push @params => $regex;
    }

    # Match events?
    if (my $e = delete $p{event} ) {
        my ($in, @vals) = $self->_in_expr( $e );
        push @wheres => "e.event $in";
        push @params => @vals;
    }

    # Assemble the where clause.
    my $where = @wheres
        ? "\n         WHERE " . join( "\n               ", @wheres )
        : '';

    # Handle remaining parameters.
    my $limits = '';
    if (exists $p{limit} || exists $p{offset}) {
        my ($exprs, $values) = $self->_limit_offset(delete $p{limit}, delete $p{offset});
        if (@{ $exprs}) {
            $limits = join "\n         ", '', @{ $exprs };
            push @params => @{ $values || [] };
        }
    }

    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = sprintf $self->_ts2char_format, 'e.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'e.planned_at';
    my $sth = $self->dbh->prepare(qq{
        SELECT e.event
             , e.project
             , e.change_id
             , e.change
             , e.note
             , e.requires
             , e.conflicts
             , e.tags
             , e.committer_name
             , e.committer_email
             , $cdtcol AS committed_at
             , e.planner_name
             , e.planner_email
             , $pdtcol AS planned_at
          FROM events e$where
         ORDER BY e.committed_at $dir$limits
    });

    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub _limit_offset {
    my ($self, $lim, $off)  = @_;
    my (@limits, @params);

    if ($lim) {
        push @limits => 'LIMIT ?';
        push @params => $lim;
    }
    if ($off) {
        if (!$lim && ($lim = $self->_limit_default)) {
            # Some drivers require LIMIT when OFFSET is set.
            push @limits => 'LIMIT ?';
            push @params => $lim;
        }
        push @limits => 'OFFSET ?';
        push @params => $off;
    }
    return \@limits, \@params;
}

sub registered_projects {
    return @{ shift->dbh->selectcol_arrayref(
        'SELECT project FROM projects ORDER BY project'
    ) };
}

sub register_project {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $dbh    = $self->dbh;
    my $plan   = $self->plan;
    my $proj   = $plan->project;
    my $uri    = $plan->uri;

    my $res = $dbh->selectcol_arrayref(
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
        my $res = defined $uri ? $dbh->selectcol_arrayref(
            'SELECT project FROM projects WHERE uri = ?',
            undef, $uri
        ) : $dbh->selectcol_arrayref(
            'SELECT project FROM projects WHERE uri IS NULL',
        );

        hurl engine => __x(
            'Cannot register "{project}" with URI {uri}: project "{reg_proj}" already using that URI',
            project => $proj,
            uri     => $uri,
            reg_proj => $res->[0],
        ) if @{ $res };

        # Insert the project.
        my $ts = $self->_ts_default;
        $dbh->do(qq{
            INSERT INTO projects (project, uri, creator_name, creator_email, created_at)
            VALUES (?, ?, ?, ?, $ts)
        }, undef, $proj, $uri, $sqitch->user_name, $sqitch->user_email);
    }

    return $self;
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1
              FROM changes
             WHERE change_id = ?
        )
    }, undef, $change->id)->[0];
}

sub are_deployed_changes {
    my $self = shift;
    my $qs = join ', ' => ('?') x @_;
    @{ $self->dbh->selectcol_arrayref(
        "SELECT change_id FROM changes WHERE change_id IN ($qs)",
        undef,
        map { $_->id } @_,
    ) };
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1
              FROM tags
             WHERE tag_id = ?
        );
    }, undef, $tag->id)->[0];
}

sub _multi_values {
    my ($self, $count, $expr) = @_;
    return 'VALUES ' . join(', ', ("($expr)") x $count)
}

sub _dependency_placeholders {
    return '?, ?, ?, ?';
}

sub _tag_placeholders {
    my $self = shift;
    return '?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ' . $self->_ts_default;
}

sub _tag_subselect_columns {
    my $self = shift;
    return join(', ',
        '? AS tid',
        '? AS tname',
        '? AS proj',
        '? AS cid',
        '? AS note',
        '? AS cuser',
        '? AS cemail',
        '? AS tts',
        '? AS puser',
        '? AS pemail',
        $self->_ts_default,
    );
}

sub _prepare_to_log { $_[0] }

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

    my $ts = $self->_ts_default;
    my $cols = join "\n            , ", $self->_quote_idents(qw(
        change_id
        script_hash
        change
        project
        note
        committer_name
        committer_email
        planned_at
        planner_name
        planner_email
        committed_at
    ));

    $self->_prepare_to_log(changes => $change);
    $dbh->do(qq{
        INSERT INTO changes (
            $cols
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $id,
        $change->script_hash,
        $name,
        $proj,
        $change->note,
        $user,
        $email,
        $self->_char2ts( $change->timestamp ),
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
           ) } . $self->_multi_values(scalar @deps, $self->_dependency_placeholders),
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
                , committed_at
           ) } . $self->_multi_values(scalar @tags, $self->_tag_placeholders),
            undef,
            map { (
                $_->id,
                $_->format_name,
                $proj,
                $id,
                $_->note,
                $user,
                $email,
                $self->_char2ts( $_->timestamp ),
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
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    my $ts   = $self->_ts_default;
    my $cols = join "\n            , ", $self->_quote_idents(qw(
        event
        change_id
        change
        project
        note
        tags
        requires
        conflicts
        committer_name
        committer_email
        planned_at
        planner_name
        planner_email
        committed_at
    ));

    $self->_prepare_to_log(events => $change);
    $dbh->do(qq{
        INSERT INTO events (
            $cols
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        $tags      || $self->_log_tags_param($change),
        $requires  || $self->_log_requires_param($change),
        $conflicts || $self->_log_conflicts_param($change),
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    return @{ $self->dbh->selectall_arrayref(q{
        SELECT c.change_id, c.project, c.change, (
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.project       = c.project
               AND c2.committed_at >= c.committed_at
             ORDER BY c2.committed_at
             LIMIT 1
        ) AS asof_tag
          FROM dependencies d
          JOIN changes c ON c.change_id = d.change_id
         WHERE d.dependency_id = ?
    }, { Slice => {} }, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT c.change || COALESCE((
            SELECT tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
               AND c2.project = c.project
             LIMIT 1
        ), '@HEAD')
          FROM changes c
         WHERE change_id = ?
    }, undef, $change_id)->[0];
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

    my $subselect = 'SELECT ' . $self->_tag_subselect_columns . $self->_simple_from;
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
                 , committed_at
            )
            SELECT i.* FROM (
                         } . join(
                "\n               UNION ALL ",
                ($subselect) x @tags
            ) . q{
            ) i
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
            $self->_char2ts( $_->timestamp ),
            $_->planner_name,
            $_->planner_email,
        ) } @tags
    );

    return $self;
}

sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->dbh;
    my $cid = $change->id;

    # Retrieve and delete tags.
    my $del_tags = join ',' => @{ $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ?',
        undef, $cid
    ) || [] };

    $dbh->do(
        'DELETE FROM tags WHERE change_id = ?',
        undef, $cid
    );

    # Retrieve dependencies and delete.
    my $sth = $dbh->prepare(q{
        SELECT dependency
          FROM dependencies
         WHERE change_id = ?
           AND type      = ?
    });
    my $req = join ',' => @{ $dbh->selectcol_arrayref(
        $sth, undef, $cid, 'require'
    ) };

    my $conf = join ',' => @{ $dbh->selectcol_arrayref(
        $sth, undef, $cid, 'conflict'
    ) };

    $dbh->do('DELETE FROM dependencies WHERE change_id = ?', undef, $cid);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $cid,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

sub deployed_changes {
    my $self   = shift;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    return map {
        $_->{timestamp} = _dt $_->{timestamp};
        unless (ref $_->{tags}) {
            $_->{tags} = $_->{tags} ? [ split / / => $_->{tags} ] : [];
        }
        $_;
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email, c.committed_at
         ORDER BY c.committed_at ASC
    }, { Slice => {} }, $self->plan->project) };
}

sub deployed_changes_since {
    my ( $self, $change ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    return map {
        $_->{timestamp} = _dt $_->{timestamp};
        unless (ref $_->{tags}) {
            $_->{tags} = $_->{tags} ? [ split / / => $_->{tags} ] : [];
        }
        $_;
    } @{ $self->dbh->selectall_arrayref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
           AND c.committed_at > (SELECT committed_at FROM changes WHERE change_id = ?)
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email, c.committed_at
         ORDER BY c.committed_at ASC
    }, { Slice => {} }, $self->plan->project, $change->id) };
}

sub load_change {
    my ( $self, $change_id ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
                $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.change_id = ?
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email
    }, undef, $change_id) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    unless (ref $change->{tags}) {
        $change->{tags} = $change->{tags} ? [ split / / => $change->{tags} ] : [];
    }
    return $change;
}

sub _offset_op {
    my ( $self, $offset ) = @_;
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
    return $dir, $op, 'OFFSET ' . (abs($offset) - 1);
}

sub change_id_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the ID if there is no offset.
    return $change_id unless $offset;

    my ($dir, $op, $offset_expr) = $self->_offset_op($offset);
    return $self->dbh->selectcol_arrayref(qq{
        SELECT change_id
          FROM changes
         WHERE project = ?
           AND committed_at $op (
               SELECT committed_at FROM changes WHERE change_id = ?
         )
         ORDER BY committed_at $dir
         LIMIT 1 $offset_expr
    }, undef, $self->plan->project, $change_id)->[0];
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ($dir, $op, $offset_expr) = $self->_offset_op($offset);
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';

    my $change = $self->dbh->selectrow_hashref(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               $tagcol AS tags
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
           AND c.committed_at $op (
               SELECT committed_at FROM changes WHERE change_id = ?
         )
         GROUP BY c.change_id, c.change, c.project, c.note, c.planned_at,
               c.planner_name, c.planner_email, c.committed_at
         ORDER BY c.committed_at $dir
         LIMIT 1 $offset_expr
    }, undef, $self->plan->project, $change_id) || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    unless (ref $change->{tags}) {
        $change->{tags} = $change->{tags} ? [ split / / => $change->{tags} ] : [];
    }
    return $change;
}

sub _cid_head {
    my ($self, $project, $change) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT change_id
          FROM changes
         WHERE project = ?
           AND changes.change  = ?
         ORDER BY committed_at DESC
         LIMIT 1
    }, undef, $project, $change)->[0];
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
            # There is nothing before the first tag.
            return undef if $tag eq 'ROOT' || $tag eq 'FIRST';

            # Find closest to the end for @HEAD.
            return $self->_cid_head($project, $change)
                if $tag eq 'HEAD' || $tag eq 'LAST';

            # Find by change name and following tag.
            my $limit = $self->_can_limit ? "\n                 LIMIT 1" : '';
            return $dbh->selectcol_arrayref(qq{
                SELECT changes.change_id
                  FROM changes
                  JOIN tags
                    ON changes.committed_at <= tags.committed_at
                   AND changes.project = tags.project
                 WHERE changes.project = ?
                   AND changes.change  = ?
                   AND tags.tag        = ?
                 ORDER BY changes.committed_at DESC$limit
            }, undef, $project, $change, '@' . $tag)->[0];
        }

        # Find earliest by change name.
        my $ids = $dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
               AND changes.change  = ?
             ORDER BY changes.committed_at ASC
        }, undef, $project, $change);

        # Return the ID.
        return $self->_handle_lookup_index($change, $ids);
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

sub _update_script_hashes {
    my $self = shift;
    my $plan = $self->plan;
    my $proj = $plan->project;
    my $dbh  = $self->dbh;
    my $sth  = $dbh->prepare(
        'UPDATE changes SET script_hash = ? WHERE change_id = ? AND script_hash = ?'
    );

    $self->begin_work;
    $sth->execute($_->script_hash, $_->id, $_->id) for $plan->changes;
    $dbh->do(q{
        UPDATE changes SET script_hash = NULL
         WHERE project = ? AND script_hash = change_id
    }, undef, $proj);

    $self->finish_work;
    return $self;
}


sub begin_work {
    my $self = shift;
    # Note: Engines should acquire locks to prevent concurrent Sqitch activity.
    $self->dbh->begin_work;
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

1;

__END__

=head1 Name

App::Sqitch::Command::checkout - An engine based on the DBI

=head1 Synopsis

  package App::Sqitch::Engine::sqlite;
  extends 'App::Sqitch::Engine';
  with 'App::Sqitch::Role::DBIEngine';

=head1 Description

This role encapsulates the common attributes and methods required by
DBI-powered engines.

=head1 Interface

=head2 Instance Methods

=head3 C<earliest_change_id>

=head3 C<latest_change_id>

=head3 C<current_state>

=head3 C<current_changes>

=head3 C<current_tags>

=head3 C<search_events>

=head3 C<registered_projects>

=head3 C<register_project>

=head3 C<is_deployed_change>

=head3 C<are_deployed_changes>

=head3 C<log_deploy_change>

=head3 C<log_fail_change>

=head3 C<changes_requiring_change>

=head3 C<name_for_change_id>

=head3 C<log_new_tags>

=head3 C<log_revert_change>

=head3 C<begin_work>

=head3 C<finish_work>

=head3 C<rollback_work>

=head3 C<is_deployed_tag>

=head3 C<deployed_changes>

=head3 C<deployed_changes_since>

=head3 C<load_change>

=head3 C<change_offset_from_id>

=head3 C<change_id_offset_from_id>

=head3 C<change_id_for>

=head3 C<registry_version>

=head1 See Also

=over

=item L<App::Sqitch::Engine::pg>

The PostgreSQL engine.

=item L<App::Sqitch::Engine::sqlite>

The SQLite engine.

=item L<App::Sqitch::Engine::oracle>

The Oracle engine.

=item L<App::Sqitch::Engine::mysql>

The MySQL engine.

=item L<App::Sqitch::Engine::vertica>

The Vertica engine.

=item L<App::Sqitch::Engine::exasol>

The Exasol engine.

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
