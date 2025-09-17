package App::Sqitch::Engine::clickhouse;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use Path::Class;
use Moo;
use App::Sqitch::Types qw(DBH URIDB ArrayRef Str HashRef);
use namespace::autoclean;
use List::MoreUtils qw(firstidx);

extends 'App::Sqitch::Engine';

# VERSION

has uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri = $self->SUPER::uri;
        $uri->host($ENV{CLICKHOUSE_HOST}) if !$uri->host  && $ENV{CLICKHOUSE_HOST};
        return $uri;
    },
);

has registry_uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri = $self->uri->clone;
        $uri->dbname($self->registry);
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

has _clickcnf => (
    is => 'rw',
    isa     => HashRef,
    default => sub {
        # XXX Need to create a module to parse the ClickHouse CLI format.
        # https://clickhouse.com/docs/interfaces/cli#configuration_files
        return {}
    },
);

sub _def_user { $ENV{CLICKHOUSE_USER} || $_[0]->_clickcnf->{user} || $_[0]->sqitch->sysuser }
sub _def_pass { $ENV{CLICKHOUSE_PASSWORD} || shift->_clickcnf->{password} }
sub _dsn { shift->registry_uri->dbi_dsn }

use Test::More;

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;
        return DBI->connect($self->_dsn, $self->username, $self->password, {
            PrintError   => 0,
            RaiseError   => 0,
            AutoCommit   => 1,
            HandleError  => $self->error_handler,
            odbc_utf8_on => 1,
        });
    }
);

has _ts_default => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub { q{now64(6, 'UTC')} },
);

# Need to wait until dbh and _ts_default are defined.
with 'App::Sqitch::Role::DBIEngine';

has _cli => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;

        $self->sqitch->warn(__x
            'Database name missing in URI "{uri}"',
            uri => $uri
        ) unless $uri->dbname;

        my @ret = ($self->client);
        push @ret => 'client' if $ret[0] !~ /-client$/;
        # Use _port instead of port so it's empty if no port is in the URI.
        # https://github.com/sqitchers/sqitch/issues/675
        for my $spec (
            [ user     => $self->username ],
            [ password => $self->password ],
            [ database => $uri->dbname    ],
            [ host     => $uri->host      ],
            [ port     => $uri->_port     ],
        ) {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        # Options to keep things quiet.
        push @ret => (
            '--progress' => 'off',
            '--disable_suggestion',
            '--progress-table' => 'off',
        );

        # Add relevant query args.
        if (my @p = $uri->query_params) {
            while (@p) {
                my ($k, $v) = (shift @p, shift @p);
                push @ret => '--secure' if lc $k eq 'sslmode' && $v eq 'require';
            }
        }
        return \@ret;
    },
);

sub cli { @{ shift->_cli } }

sub key    { 'clickhouse' }
sub name   { 'ClickHouse' }
sub driver { 'DBD::ODBC 1.59' }
# XXX Search path for clickhouse-client or just clickhouse?
sub default_client { 'clickhouse-client' }

sub _char2ts { $_[1]->set_time_zone('UTC')->iso8601 }

sub _ts2char_format {
    q{formatDateTime(%s, 'year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%i:second:%%S:time_zone:UTC')};
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

sub _limit_offset {
    # LIMIT/OFFSET don't support parameters, alas. So just put them in the query.
    my ($self, $lim, $off)  = @_;
    return ["LIMIT $lim", "OFFSET $off"], [] if $lim && $off;
    return ["LIMIT $lim"], [] if $lim;
    return ["OFFSET $off"], [] if $off;
    return [], [];
}

# ClickHouse ODBC does not support arrays. So we must parse them manually.
# I'd rather not do an eval, so rip this out once the issue is fixed.
# https://github.com/clickHouse/clickhouse-odbc/issues/525
sub _parse_array {
    return [] unless $_[1];
    my $list = eval $_[1];
    return [] unless $list;
    pop @{ $list } if @{ $list } && $list->[0] eq '';
    return $list;
}

sub _version_query { 'SELECT CAST(ROUND(MAX(version), 1) AS CHAR) FROM releases' }

sub _initialized {
    my $self = shift;
    return try {
        $self->dbh->selectcol_arrayref(q{
            SELECT true
             FROM information_schema.tables
            WHERE TABLE_CATALOG = current_database()
              AND TABLE_SCHEMA  = ?
              AND TABLE_NAME    = ?
        }, undef, $self->registry, 'changes')->[0]
    } catch {
        return 0 if $DBI::state && $DBI::state eq 'HY000';
        die $_;
    }
}

sub _initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->registry,
    ) if $self->initialized;

    # Create the Sqitch database if it does not exist.
    (my $db = $self->registry) =~ s/"/""/g;
    $self->_run(
        '--query' => sprintf(
            q{CREATE DATABASE IF NOT EXISTS "%s" COMMENT 'Sqitch database deployment metadata v%s'},
            $self->registry, $self->registry_release,
        ),
    );

    # Deploy the registry to the Sqitch database.
    $self->run_upgrade( file(__FILE__)->dir->file('clickhouse.sql') );
    $self->_register_release;
}

sub _no_table_error  {
    # /HTTP status code: 404$/
    return $DBI::state && $DBI::state eq 'HY000'; # General Error
}

sub _no_column_error  {
    return $DBI::state && $DBI::state eq '42703'; # ERRCODE_UNDEFINED_COLUMN
}

sub _unique_error  {
    # ClickHouse doe not support unique constraints.
    return 0;
}

sub _regex_op { 'REGEXP' }

sub _listagg_format { q{groupArraySorted(10000)(%1$s)} }

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    my $off = $offset ? " OFFSET $offset" : '';
    return try {
        return $self->dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1$off
        }, undef, $project || $self->plan->project)->[0];
    } catch {
        return if $self->_no_table_error && !$self->initialized;
        die $_;
    };
}

# Override to query for existing tags separately.
sub _log_event {
    my ( $self, $event, $change, $tags, $requires, $conflicts) = @_;
    my $dbh    = $self->dbh;
    my $sqitch = $self->sqitch;

    $tags      ||= $self->_log_tags_param($change);
    $requires  ||= $self->_log_requires_param($change);
    $conflicts ||= $self->_log_conflicts_param($change);

    # Use the array() constructor to insert arrays of values. Remove if
    # https://github.com/clickHouse/clickhouse-odbc/issues/525 fixed.
    my $tag_ph = 'array('. join(', ', ('?') x @{ $tags      }) . ')';
    my $req_ph = 'array('. join(', ', ('?') x @{ $requires  }) . ')';
    my $con_ph = 'array('. join(', ', ('?') x @{ $conflicts }) . ')';
    my $ts     = $self->_ts_default;

    $dbh->do(qq{
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
            , committed_at
        )
        VALUES (?, ?, ?, ?, ?, $tag_ph, $req_ph, $con_ph, ?, ?, ?, ?, ?, $ts)
    }, undef,
        $event,
        $change->id,
        $change->name,
        $change->project,
        $change->note,
        @{ $tags      },
        @{ $requires  },
        @{ $conflicts },
        $sqitch->user_name,
        $sqitch->user_email,
        $self->_char2ts( $change->timestamp ),
        $change->planner_name,
        $change->planner_email,
    );

    return $self;
}

# Override to save tags as an array rather than a space-delimited string.
sub log_revert_change {
    my ($self, $change) = @_;
    my $dbh = $self->dbh;
    my $cid = $change->id;

    # Retrieve and delete tags.
    my $del_tags = $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ?',
        undef, $cid
    ) || {};

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

    my $req = $dbh->selectcol_arrayref( $sth, undef, $cid, 'require' );
    my $conf = $dbh->selectcol_arrayref( $sth, undef, $cid, 'conflict' );

    $dbh->do('DELETE FROM dependencies WHERE change_id = ?', undef, $cid);

    # Delete the change record.
    $dbh->do(
        'DELETE FROM changes where change_id = ?',
        undef, $cid,
    );

    # Log it.
    return $self->_log_event( revert => $change, $del_tags, $req, $conf );
}

# NOTE: Query from DBIEngine doesn't work in ClickHouse:
#   DB::Exception: Current query is not supported yet, because can't find
#   correlated column [...] (NOT_IMPLEMENTED)
# Looks like it doesn't yet support correlated subqueries. The CTE-based query
# adapted from Exasol seems to be fine, however.
sub changes_requiring_change {
    my ( $self, $change ) = @_;
    # Weirdly, ClickHouse doesn't inject NULLs when the tag window query
    # returns no rows, but empty values: "" for tag name and 0 for rank. Use
    # multiIf() to change an empty string to a NULL, and compare rank to <= 1
    # instead of bothering with NULLs.
    return @{ $self->dbh->selectall_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT c.change_id AS change_id,
               c.project   AS project,
               c.change    AS change,
               multiIf(t.tag == '', NULL, t.tag) AS asof_tag
          FROM dependencies d
          JOIN changes  c ON c.change_id = d.change_id
          LEFT JOIN tag t ON t.project   = c.project AND t.committed_at >= c.committed_at
         WHERE d.dependency_id = ?
           AND t.rnk <= 1
    }, { Slice => {} }, $change->id) };
}

# NOTE: Query from DBIEngine doesn't work in ClickHouse:
#   DB::Exception: Current query is not supported yet, because can't find \
#   correlated column '__table4.committed_at' in current header: [...] (NOT_IMPLEMENTED)
# Looks like it doesn't yet support correlated subqueries. The CTE-based query
# adapted from Exasol seems to be fine, however.
sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    # Weirdly, ClickHouse doesn't inject NULLs when the tag window query
    # returns no rows, but empty values: "" for tag name and 0 for rank. Use
    # multiIf() to change an empty string to a NULL, and compare rank to <= 1
    # instead of bothering with NULLs.
    return $self->dbh->selectcol_arrayref(q{
        WITH tag AS (
            SELECT multiIf(tag == '', NULL, tag) AS tag,
                   committed_at,
                   project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT change || COALESCE(t.tag, '@HEAD')
          FROM changes c
          LEFT JOIN tag t ON c.project = t.project AND t.committed_at >= c.committed_at
         WHERE change_id = ?
           AND t.rnk <= 1
    }, undef, $change_id)->[0];
}

# There is a bug in ClickHouse EXISTS(), so do without it.
# https://github.com/ClickHouse/ClickHouse/issues/86415
sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM changes WHERE change_id = ?',
        undef, $change->id
    )->[0];
}

# There is a bug in ClickHouse EXISTS(), so do without it.
# https://github.com/ClickHouse/ClickHouse/issues/86415
sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(
        'SELECT 1 FROM tags WHERE tag_id = ?',
        undef, $tag->id,
    )->[0];
}

# Override to query for existing tags in a separate query. The LEFT JOIN/UNION
# dance simply didn't work in ClickHouse.
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

    # Get a list of existing tags.
    my $in = join ', ', ('?') x @tags;
    my %exists = map { $_ => undef } $self->dbh->selectrow_array(
        "SELECT tag_id FROM tags WHERE tag_id IN($in)",
        undef, map { $_->id } @tags,
    );

    # Filter out the existing tags.
    @tags = grep { ! exists $exists{$_->id} } @tags;
    return $self unless @tags;

    # Insert the new tags.
    my $row = q{(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)};
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
            ) VALUES
                } . join( ",\n                ", ($row) x @tags ),
        undef,
        map { (
            $_->id,
            $_->format_name,
            $proj,
            $id,
            $_->note,
            $user,
            $email,
            $self->_char2ts($_->timestamp),
            $_->planner_name,
            $_->planner_email,
        ) } @tags
    );

    return $self;
}

# Wrap _select_state to parse the tags into an array. Remove if and when
# clickhouse-odbc properly supports arrays. Remove if
# https://github.com/clickHouse/clickhouse-odbc/issues/525 fixed.
around _select_state => sub {
    my ($orig, $self) = (shift, shift);
    my $state = $self->$orig(@_);
    $state->{tags} = $self->_parse_array($state->{tags})
        if $state && $state->{tags};
    return $state;
};

sub _run {
    my $self = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->cli, @_ );
    local $ENV{CLICKHOUSE_PASSWORD} = $pass;
    return $sqitch->run( $self->cli, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->cli, @_ );
    local $ENV{CLICKHOUSE_PASSWORD} = $pass;
    return $sqitch->capture( $self->cli, @_ );
}

sub _spool {
    my $self   = shift;
    my @fh     = (shift);
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->spool( \@fh, $self->cli, @_ );
    local $ENV{CLICKHOUSE_PASSWORD} = $pass;
    return $sqitch->spool( \@fh, $self->cli, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--queries-file' => $file);
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth('--queries-file' => $file);
}

sub run_upgrade {
    my ($self, $file) = @_;
    my @cmd = $self->cli;

    if ((my $idx = firstidx { $_ eq '--database' } @cmd) > 0) {
        # Replace the database name with the registry database.
        $cmd[$idx + 1] = $self->registry;
    } else {
        # Append the registry database name.
        push @cmd => '--database', $self->registry;
    }

    return $self->sqitch->run(@cmd, '--queries-file' => $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

1;

__END__

=head1 Name

App::Sqitch::Engine::clickhouse - Sqitch ClickHouse Engine

=head1 Synopsis

  my $clickhouse = App::Sqitch::Engine->load( engine => 'clickhouse' );

=head1 Description

App::Sqitch::Engine::clickhouse provides the ClickHouse storage engine for Sqitch. It
supports ClickHouse 5.1.0 and higher (best on 5.6.4 and higher), as well as MariaDB
5.3.0 and higher.

=head1 Interface

=head2 Instance Methods

=head3 C<clickhouse>

Returns a list containing the C<clickhouse> client and options to be passed to it.
Used internally when executing scripts. Query parameters in the URI that map
to C<clickhouse> client options will be passed to the client, as follows:

=over

=item * C<clickhouse_compression=1>: C<--compress>

=item * C<clickhouse_ssl=1>: C<--ssl>

=item * C<clickhouse_connect_timeout>: C<--connect_timeout>

=item * C<clickhouse_init_command>: C<--init-command>

=item * C<clickhouse_socket>: C<--socket>

=item * C<clickhouse_ssl_client_key>: C<--ssl-key>

=item * C<clickhouse_ssl_client_cert>: C<--ssl-cert>

=item * C<clickhouse_ssl_ca_file>: C<--ssl-ca>

=item * C<clickhouse_ssl_ca_path>: C<--ssl-capath>

=item * C<clickhouse_ssl_cipher>: C<--ssl-cipher>

=back

=head3 C<username>

=head3 C<password>

Overrides the methods provided by the target so that, if the target has
no username or password, Sqitch looks them up in the
L<F</etc/my.cnf> and F<~/.my.cnf> files|https://dev.clickhouse.com/doc/refman/5.7/en/password-security-user.html>.
These files must limit access only to the current user (C<0600>). Sqitch will
look for a username and password under the C<[client]> and C<[clickhouse]>
sections, in that order.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2025 David E. Wheeler, 2012-2021 iovation Inc.

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
