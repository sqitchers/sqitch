package App::Sqitch::Engine::firebird;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use Path::Class;
use File::Basename;
use Time::Local;
use Time::HiRes qw(sleep);
use Mouse;
use namespace::autoclean;

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.992';

has registry_uri => (
    is       => 'ro',
    isa      => 'URI::db',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        my $uri  = $self->uri->clone;
        my $reg  = $self->registry;

        if ( file($reg)->is_absolute ) {
            # Just use an absolute path.
            $uri->dbname($reg);
        } elsif (my @segs = $uri->path_segments) {
            # Use the same name, but replace $name.$ext with $reg.$ext.
            my $reg = $self->registry;
            if ($reg =~ /[.]/) {
                $segs[-1] =~ s/^[^.]+(?:[.].+)?$/$reg/;
            } else {
                $segs[-1] =~ s{^[^.]+([.].+)?$}{$reg . ($1 // '')}e;
            }
            $uri->path_segments(@segs);
        } else {
            # No known path, so no name.
            $uri->dbname(undef);
        }

        return $uri;
    },
);

sub registry_destination {
    my $uri = shift->registry_uri;
    if ($uri->password) {
        $uri = $uri->clone;
        $uri->password(undef);
    }
    return $uri->as_string;
}

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $uri  = $self->registry_uri;
        $self->use_driver;

        my $dsn = $uri->dbi_dsn . ';ib_dialect=3;ib_charset=UTF8';
        return DBI->connect($dsn, scalar $uri->user, scalar $uri->password, {
            $uri->query_params,
            PrintError       => 0,
            RaiseError       => 0,
            AutoCommit       => 1,
            ib_enable_utf8   => 1,
            FetchHashKeyName => 'NAME_lc',
            HandleError          => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
        });
    }
);

has isql => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;
        my @ret  = ( $self->client );
        for my $spec (
            [ user     => $uri->user     ],
            [ password => $uri->password ],
        ) {
            push @ret, "-$spec->[0]" => $spec->[1] if $spec->[1];
        }

        push @ret => (
            '-quiet',
            '-bail',
            '-sqldialect' => '3',
            '-pagelength' => '16384',
            '-charset'    => 'UTF8',
            $self->connection_string($uri),
        );

        return \@ret;
    },
);

has tz_offset => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 1,
    default => sub {
        # From: http://stackoverflow.com/questions/2143528/whats-the-best-way-to-get-the-utc-offset-in-perl
        my @t = localtime(time);
        my $gmt_offset_in_seconds = timegm(@t) - timelocal(@t);
        my $offset = -($gmt_offset_in_seconds / 3600);
        return $offset;
    },
);

sub key    { 'firebird' }
sub name   { 'Firebird' }
sub driver { 'DBD::Firebird 1.11' }

sub _char2ts {
    my $dt = $_[1];
    $dt->set_time_zone('UTC');
    return join ' ', $dt->ymd('-'), $dt->hms(':');
}

sub _ts2char_format {
    return qq{'year:' || CAST(EXTRACT(YEAR   FROM %s) AS SMALLINT)
        || ':month:'  || CAST(EXTRACT(MONTH  FROM %1\$s) AS SMALLINT)
        || ':day:'    || CAST(EXTRACT(DAY    FROM %1\$s) AS SMALLINT)
        || ':hour:'   || CAST(EXTRACT(HOUR   FROM %1\$s) AS SMALLINT)
        || ':minute:' || CAST(EXTRACT(MINUTE FROM %1\$s) AS SMALLINT)
        || ':second:' || FLOOR(CAST(EXTRACT(SECOND FROM %1\$s) AS NUMERIC(9,4)))
        || ':time_zone:UTC'};
}

sub _ts_default {
    my $offset = shift->tz_offset;
    sleep 0.01; # give Firebird a little time to tick microseconds.
    return qq(DATEADD($offset HOUR TO CURRENT_TIMESTAMP(3)));
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    return $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM changes WHERE change_id = ?',
        undef, $change->id
    )->[0];
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(q{
            SELECT 1
              FROM tags
             WHERE tag_id = ?
    }, undef, $tag->id)->[0];
}

sub initialized {
    my $self = shift;

    # Try to connect.
    my $err = 0;
    my $dbh = try { $self->dbh } catch { $err = $DBI::err; $self->sqitch->debug($_); };
    return 0 if $err;

    return $self->dbh->selectcol_arrayref(qq{
        SELECT COUNT(RDB\$RELATION_NAME)
            FROM RDB\$RELATIONS
            WHERE RDB\$SYSTEM_FLAG=0
                  AND RDB\$VIEW_BLR IS NULL
                  AND RDB\$RELATION_NAME = ?
    }, undef, 'CHANGES')->[0];
}

sub initialize {
    my $self = shift;
    my $uri  = $self->registry_uri;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $uri->dbname,
    ) if $self->initialized;

    my $sqitch_db = $self->connection_string($uri);

    # Create the registry database if it does not exist.
    $self->use_driver;
    try {
        DBD::Firebird->create_database({
            db_path       => $sqitch_db,
            user          => scalar $uri->user,
            password      => scalar $uri->password,
            character_set => 'UTF8',
            page_size     => 16384,
        });
    }
    catch {
        hurl firebird => __x(
            'Cannot create database {database}: {error}',
            database => $sqitch_db,
            error    => $_,
        );
    };

    # Load up our database. The database must exist!
    my @cmd    = $self->isql;
    $cmd[-1]   = $sqitch_db;
    my $file   = file(__FILE__)->dir->file('firebird.sql');
    my $sqitch = $self->sqitch;
    $sqitch->run( @cmd, '-input' => $sqitch->quote_shell($file) );
}

sub connection_string {
    my ($self, $uri) = @_;
    my $file = $uri->dbname or hurl firebird => __x(
        'Database name missing in URI {uri}',
        uri => $uri,
    );
    my $host = $uri->host   or return $file;
    my $port = $uri->_port  or return "$host:$file";
    return "$host/$port:$file";
}

# Override to lock the Sqitch tables. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock all tables to disallow concurrent changes.
    # This should be equivalent to 'LOCK TABLE changes' ???
    # http://conferences.embarcadero.com/article/32280#TableReservation
    $dbh->func(
        -lock_resolution => 'no_wait',
        -reserving => {
            changes => {
                lock   => 'read',
                access => 'protected',
            },
        },
        'ib_set_tx_param'
    );
    $dbh->begin_work;
    return $self;
}

# Override to unlock the tables, otherwise future transactions on this
# connection can fail.
sub finish_work {
    my $self = shift;
    my $dbh = $self->dbh;
    $dbh->commit;
    $dbh->func( 'ib_set_tx_param' );         # reset parameters
    return $self;
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _no_table_error  {
    return $DBI::errstr && $DBI::errstr =~ /^\Q\-Table unknown/; # ???
}

sub _regex_op { 'SIMILAR TO' }               # NOT good match for
                                             # REGEXP :(

sub _limit_default { '18446744073709551615' }

sub _listagg_format {
    return q{LIST(ALL %s, ' ')}; # Firebird v2.1.4 minimum
}

sub _run {
    my $self = shift;
    return $self->sqitch->run( $self->isql, @_ );
}

sub _capture {
    my $self = shift;
    return $self->sqitch->capture( $self->isql, @_ );
}

sub _spool {
    my $self = shift;
    my $fh   = shift;
    return $self->sqitch->spool( $fh, $self->isql, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run( '-input' => $file );
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '-input' => $file );
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    my $offexpr = $offset ? " SKIP $offset" : '';
    return try {
        return $self->dbh->selectcol_arrayref(qq{
            SELECT FIRST 1$offexpr change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord;
        }, undef, $project || $self->plan->project)->[0];
    } catch {
        # Firebird generic error code -902, one possible message:
        # -I/O error during "open" operation for file...
        # -Error while trying to open file
        # -No such file or directory
        # print "===DBI ERROR: $DBI::err\n";
        return if $DBI::err == -902;       # can't connect to database
        die $_;
    };
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';
    my $dbh    = $self->dbh;

    my $state  = $dbh->selectrow_hashref(qq{
        SELECT FIRST 1 c.change_id
             , c.change
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
             , c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , c.committed_at
             , c.planner_name
             , c.planner_email
             , c.planned_at
         ORDER BY c.committed_at DESC
    }, undef, $project // $self->plan->project ) or return undef;
    unless (ref $state->{tags}) {
        $state->{tags} = $state->{tags} ? [ split / / => $state->{tags} ] : [];
    }
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
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
        # Trying to adapt REGEXP for SIMILAR TO from Firebird 2.5 :)
        # Yes, I know is ugly...
        # There is no support for ^ and $ as in normal REGEXP.
        #
        # From the docs:
        # Description: SIMILAR TO matches a string against an SQL
        # regular expression pattern. UNLIKE in some other languages,
        # the pattern MUST MATCH THE ENTIRE STRING in order to succeed
        # – matching a substring is not enough. If any operand is
        # NULL, the result is NULL. Otherwise, the result is TRUE or
        # FALSE.
        #
        # Maybe use the CONTAINING operator instead?
        # print "===REGEX: $regex\n";
        if ( $regex =~ m{^\^} and $regex =~ m{\$$} ) {
            $regex =~ s{\^}{};
            $regex =~ s{\$}{};
            $regex = "%$regex%";
        }
        else {
            if ( $regex !~ m{^\^} and $regex !~ m{\$$} ) {
                $regex = "%$regex%";
            }
        }
        if ( $regex =~ m{\$$} ) {
            $regex =~ s{\$}{};
            $regex = "%$regex";
        }
        if ( $regex =~ m{^\^} ) {
            $regex =~ s{\^}{};
            $regex = "$regex%";
        }
        # print "== SIMILAR TO: $regex\n";
        push @wheres => "$spec->[1] $op ?";
        push @params => "$regex";
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
        my $lim = delete $p{limit};
        if ($lim) {
            $limits = " FIRST ? ";
            push @params => $lim;
        }
        if (my $off = delete $p{offset}) {
            $limits .= " SKIP ? ";
            push @params => $off;
        }
    }

    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    $self->dbh->{ib_softcommit} = 1;

    # Prepare, execute, and return.
    my $cdtcol = sprintf $self->_ts2char_format, 'e.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'e.planned_at';
    my $sth = $self->dbh->prepare(qq{
        SELECT $limits e.event
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
         ORDER BY e.committed_at $dir
    });
    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    return @{ $self->dbh->selectall_arrayref(q{
        SELECT c.change_id, c.project, c.change, (
            SELECT FIRST 1 tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.project      = c.project
               AND c2.committed_at >= c.committed_at
             ORDER BY c2.committed_at
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
            SELECT FIRST 1 tag
              FROM changes c2
              JOIN tags ON c2.change_id = tags.change_id
             WHERE c2.committed_at >= c.committed_at
               AND c2.project = c.project
        ), '')
          FROM changes c
         WHERE change_id = ?
    }, undef, $change_id)->[0];
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my $tagcol = sprintf $self->_listagg_format, 't.tag';

    $offset = abs($offset) - 1;
    my ($offset_expr, $limit_expr) = ('', '');
    if ($offset) {
        $offset_expr = "SKIP $offset";
    }

    my $sql = qq{
        SELECT $limit_expr $offset_expr
               c.change_id AS "id", c.change AS name, c.project, c.note,
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
    };
    my $change
        = $self->dbh->selectrow_hashref( $sql, undef, $self->plan->project,
        $change_id )
        || return undef;
    $change->{timestamp} = _dt $change->{timestamp};
    unless ( ref $change->{tags} ) {
        $change->{tags}
            = $change->{tags} ? [ split / / => $change->{tags} ] : [];
    }
    return $change;
}

sub _cid_head {
    my ($self, $project, $change) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT FIRST 1 change_id
          FROM changes
         WHERE project = ?
           AND changes.change  = ?
         ORDER BY committed_at DESC
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
            return $dbh->selectcol_arrayref(q{
                SELECT changes.change_id
                  FROM changes
                  JOIN tags
                    ON changes.committed_at <= tags.committed_at
                   AND changes.project = tags.project
                 WHERE changes.project = ?
                   AND changes.change  = ?
                   AND tags.tag        = ?
            }, undef, $project, $change, '@' . $tag)->[0];
        }

        # Find earliest by change name.
        my $limit = $self->_can_limit ? " FIRST 1" : '';
        return $dbh->selectcol_arrayref(qq{
            SELECT $limit change_id
              FROM changes
             WHERE project = ?
               AND changes.change  = ?
             ORDER BY changes.committed_at ASC
        }, undef, $project, $change)->[0];
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

    my $ts = $self->_ts_default;
    my $sf = $self->_simple_from;

    my $sql = q{
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
                ("SELECT CAST(? AS CHAR(40)) AS tid
                       , CAST(? AS VARCHAR(250)) AS tname
                       , CAST(? AS VARCHAR(255)) AS proj
                       , CAST(? AS CHAR(40)) AS cid
                       , CAST(? AS VARCHAR(4000)) AS note
                       , CAST(? AS VARCHAR(512)) AS cuser
                       , CAST(? AS VARCHAR(512)) AS cemail
                       , CAST(? AS TIMESTAMP) AS tts
                       , CAST(? AS VARCHAR(512)) AS puser
                       , CAST(? AS VARCHAR(512)) AS pemail
                       , CAST($ts$sf AS TIMESTAMP) AS cts"
             ) x @tags ) . q{
               FROM RDB$DATABASE ) i
               LEFT JOIN tags ON i.tid = tags.tag_id
               WHERE tags.tag_id IS NULL
        };
    my @params = map { (
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
        ) } @tags;
    $self->dbh->do($sql, undef, @params );
    return $self;
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

    my $ts = $self->_ts_default;
    my $cols = join "\n            , ", $self->_quote_idents(qw(
        change_id
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
    $dbh->do(qq{
        INSERT INTO changes (
            $cols
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $id,
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
        foreach my $dep (@deps) {
            my $sql = q{
            INSERT INTO dependencies (
                  change_id
                , type
                , dependency
                , dependency_id
           ) VALUES ( ?, ?, ?, ? ) };
            $dbh->do( $sql, undef,
                ( $id, $dep->type, $dep->as_string, $dep->resolved_id ) );
        }
    }

    if ( my @tags = $change->tags ) {
        foreach my $tag (@tags) {
            my $sql = qq{
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
           ) VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, $ts) };
            $dbh->do(
                $sql, undef,
                (   $tag->id,           $tag->format_name,
                    $proj,              $id,
                    $tag->note,         $user,
                    $email,             $self->_char2ts( $tag->timestamp ),
                    $tag->planner_name, $tag->planner_email,
                )
            );
        }
    }

    return $self->_log_event( deploy => $change );
}

sub default_client {
    my $self   = shift;
    my $ext    = $^O eq 'MSWin32' || $^O eq 'cygwin' ? '.exe' : '';

    # Create a script to run.
    require File::Temp;
    my $fh = File::Temp->new( CLEANUP => 1 );
    my @opts = (qw(-z -q -i), $fh->filename);
    $fh->print("quit;\n");
    $fh->close;

    # Suppress STDERR, including in subprocess.
    open my $olderr, '>&', \*STDERR or hurl firebird => __x(
        'Cannot dup STDERR: {error}', $!
    );
    close STDERR;
    open STDERR, '>', \my $stderr or hurl firebird => __x(
        'Cannot reirect STDERR: {error}', $!
    );

    # Try to find a client in the path.
    for my $try ( map { $_ . $ext  } qw(fbsql isql-fb isql) ) {
        my $loops = 0;
        for my $dir (File::Spec->path) {
            my $path = file $dir, $try;
            $path = Win32::GetShortPathName($path) if $^O eq 'MSWin32';
            if (-f $path && -x $path) {
                if (try { App::Sqitch->probe($path, @opts) =~ /Firebird/ } ) {
                    # Restore STDERR and return.
                    open STDERR, '>&', $olderr or hurl firebird => __x(
                        'Cannot dup STDERR: {error}', $!
                    );
                    return $loops ? $path->stringify : $try;
                }
                $loops++;
            }
        }
    }

    # Restore STDERR and die.
    open STDERR, '>&', $olderr or hurl firebird => __x(
        'Cannot dup STDERR: {error}', $!
    );
    hurl firebird => __(
        'Unable to locate Firebird ISQL; set "core.firebird.client" via sqitch config'
    );
}

1;

no Mouse;
__PACKAGE__->meta->make_immutable;

1;

__END__

=encoding utf8

=head1 Name

App::Sqitch::Engine::firebird - Sqitch Firebird Engine

=head1 Synopsis

  my $firebird = App::Sqitch::Engine->load( engine => 'firebird' );

=head1 Description

App::Sqitch::Engine::firebird provides the Firebird storage engine for Sqitch.

=head1 Interface

=head2 Accessors

=head3 C<client>

Returns the path to the Firebird client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.firebird.client> configuration value, or else defaults to C<fbsql>,
C<isql-fb>, or C<isql>, whichever appears first in the path and appears to be
Firebird interactive SQL utility. The value will end in C<.exe> on Windows. An
exception will be thrown if none of these can be found in the path, or if none
look like the Firebird interactive SQL utility.

=head2 Instance Methods

=head3 C<connection_string>

Constructs a connection string from a database URI for passing to C<isql>.

=head1 Author

David E. Wheeler <david@justatheory.com>

Ștefan Suciu <stefan@s2i2.ro>

=head1 License

Copyright (c) 2012-2014 iovation Inc.

Copyright (c) 2013 Ștefan Suciu

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
