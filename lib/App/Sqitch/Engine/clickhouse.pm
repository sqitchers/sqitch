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
use Scalar::Util qw(looks_like_number);
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
    default  => \&_setup_uri,
);

sub _setup_uri {
    my $self = shift;
    my $uri = $self->SUPER::uri;
    my $cfg = $self->_clickcnf;
    if (!$uri->host && (my $host = $ENV{CLICKHOUSE_HOST} || $cfg->{host})) {
        $uri->host($host);
    }
    if (!$uri->dbname && (my $db = $cfg->{database})) {
        $uri->dbname($db);
    }

    # Use HTTPS port if CLI using native TLS port.
    # https://clickhouse.com/docs/guides/sre/network-ports
    $uri->port(8443) if !$uri->_port && ($cfg->{port} || 0) == 9440;

    # Always require secure connections when required.
    # https://github.com/ClickHouse/ClickHouse/blob/faf6d05/src/Client/ConnectionParameters.cpp#L27-L43
    if (
        $cfg->{secure}
        || ($cfg->{port} || 0) == 9440 # assume both native and http should be secure or not.
        || ($uri->host || '') =~ /\.clickhouse(?:-staging)?\.cloud\z/
    ) {
        $uri->query_param( SSLMode => 'require' )
            unless $uri->query_param( 'SSLMode' );
    }

    # Add ODBC params for TLS configs.
    # https://clickhouse.com/docs/operations/server-configuration-parameters/settings
    # https://github.com/clickHouse/clickhouse-odbc?tab=readme-ov-file#configuration
    if ( my $tls = $cfg->{tls} ) {
        for my $map (
            [ privateKeyFile  => 'PrivateKeyFile'  ],
            [ certificateFile => 'CertificateFile' ],
            [ caConfig        => 'CALocation'      ],
        ) {
            if ( my $val = $tls->{ $map->[0] } ) {
                if ( my $p = $uri->query_param( $map->[1] ) ) {
                    # Ideally the ODBC param would override the config,
                    # bug there is currently no way to pass TLS options to
                    # the CLI.
                    hurl engine => __x(
                        'Client config {cfg_key} value "{cfg_val}" conflicts with ODBC param {odb_param} value "{odbc_val}"',
                        cfg_key    => "openSSL.client.$map->[0]",
                        cfg_val    => $val,
                        odbc_param => $map->[1],
                        odbc_val   => $p,
                    ) if $p ne $val;
                }
                $uri->query_param( $map->[1] => $val );
            }
        }

        # verificationMode | SSLMode
        # -----------------|---------------
        # none             | [nonexistent]
        # relaxed          | allow
        # strict           | require
        # once             | require
        if (
            (my $mode = $tls->{verificationMode})
            && !$uri->query_param( 'SSLMode' )
        ) {
            if ($mode eq 'strict' || $mode eq 'once') {
                $uri->query_param( SSLMode => 'require' );
            } elsif ($mode eq 'relaxed') {
                $uri->query_param( SSLMode => 'allow' );
            }
        }
    }

    return $uri;
}

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

sub _load_xml {
    my $path = shift;
    require XML::Tiny;
    my $doc = XML::Tiny::parsefile($path->stringify);
    return {} unless @{ $doc } > 0;
    return _xml2hash($doc->[0]);
}

sub _xml2hash {
    my $e = shift;
    my $n = $e->{content};
    # Return text if it's a text node.
    return $n->[0]{content} if @{ $n } == 1 && $n->[0]{type} eq 't';
    my $hash = {};
    for my $c (@{ $n }) {
        # We only care about element nodes.
        next if $c->{type} ne 'e';
        if (my $prev = $hash->{ $c->{name} }) {
            # Convert to an array.
            $hash->{ $c->{name} } = $prev = [$prev] unless ref $prev eq 'ARRAY';
            push @{ $prev } => _xml2hash($c)
        } else {
            $hash->{ $c->{name} } = _xml2hash($c);
        }
    }
    return $hash;
}

sub _is_true($) {
    my $val = shift || return 0;
    # https://github.com/ClickHouse/ClickHouse/blob/ce5a43c/base/poco/Util/src/AbstractConfiguration.cpp#L528C29-L547
    return $val != 0 || 0 if looks_like_number $val;
    $val = lc $val;
    return $val eq 'true' || $val eq 'yes' || $val eq 'on' || 0;
}

# Connection name defaults to host name from url, or else hostname from config
# or else localhost. Then look for that name in a connection under
# `connections_credentials`. If it exists, copy/overwrite `hostname`, `port`,
# `secure`, `user`, `password`, and `database`. Fall back on root object
# values `host` (not `hostname`) `port`, `secure`, `user`, `password`, and
# `database`.
#
# https://github.com/ClickHouse/ClickHouse/blob/d0facf0/programs/client/Client.cpp#L139-L212
sub _conn_cfg {
    my ($cfg, $host) = @_;

    # Copy root-level configs.
    my $conn = {
        (exists $cfg->{secure} ? (secure => _is_true $cfg->{secure}) : ()),
        map { ( $_ => $cfg->{$_}) } grep { $cfg->{$_} } qw(host port user password database),
    };

    # Copy client TLS config if exists.
    if (my $tls = $cfg->{openSSL}) {
        $conn->{tls} = $tls->{client} if $tls->{client};
    }

    # Copy connection credentials for this host if they exists.
    $host ||= $cfg->{host} || 'localhost';
    my $creds = $cfg->{connections_credentials} or return $conn;
    my $conns = $creds->{connection} or return $conn;
    for my $c (@{ ref $conns eq 'ARRAY' ? $conns : [$conns] }) {
        next unless ($c->{name} || '') eq $host;
        if (exists $c->{secure}) {
            $conn->{secure} = _is_true $c->{secure}
        }
        $conn->{host} = $c->{hostname} if $c->{hostname};
        $conn->{$_} = $c->{$_} for grep { $c->{$_} } qw(port user password database);
    }
    return $conn;
}

has _clickcnf => (
    is      => 'rw',
    isa     => HashRef,
    lazy    => 1,
    default => \&_load_cfg,
);

sub _load_cfg {
    my $self = shift;
    # https://clickhouse.com/docs/interfaces/cli#configuration_files
    # https://github.com/ClickHouse/ClickHouse/blob/master/src/Common/Config/getClientConfigPath.cpp
    for my $spec (
        ['.', 'clickhouse-client'],
        [App::Sqitch::Config->home_dir, '.clickhouse-client'],
        ['etc', 'clickhouse-client'],
    ) {
        for my $ext (qw(xml yaml yml)) {
            my $path = file $spec->[0], "$spec->[1].$ext";
            next unless -f $path;
            my $config = $ext eq 'xml' ? _load_xml $path : do {
                require YAML::Tiny;
                YAML::Tiny->read($path)->[0];
            };
            # We want the hostname specified by the user, if present.
            my $host = $ENV{CLICKHOUSE_HOST} || $self->SUPER::uri->host;
            return _conn_cfg $config, $host;
        }
    }
    return {};
}

sub _def_user { $ENV{CLICKHOUSE_USER}     || $_[0]->_clickcnf->{user}     }
sub _def_pass { $ENV{CLICKHOUSE_PASSWORD} || shift->_clickcnf->{password} }

sub _dsn {
    # Always set the host name to the default if it's not set. Otherwise
    # URI::db::_odbc returns the DSN `dbi:ODBC:DSN=sqitch;Driver=ClickHouse`.
    # We don't want that, because no such DSN exists. By setting the host
    # name, it instead returns
    # `dbi:ODBC:Server=localhost;Database=sqitch;Driver=ClickHouse`, almost
    # certainly more correct.
    my $uri = shift->registry_uri;
    unless ($uri->host) {
        $uri = $uri->clone;
        $uri->host('localhost');
    }
    return $uri->dbi_dsn
}

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
    is      => 'ro',
    isa     => ArrayRef,
    lazy    => 1,
    default => \&_load_cli,
);

sub _load_cli {
    my $self = shift;
    my $uri  = $self->uri;

    $self->sqitch->warn(__x
        'Database name missing in URI "{uri}"',
        uri => $uri
    ) unless $uri->dbname;

    my @ret = ($self->client);
    push @ret => 'client' if $ret[0] !~ /-client(?:[.]exe)?$/;
    # Omit port because the CLI needs the native port and the URL
    # specifies the HTTP port.
    for my $spec (
        [ user     => $self->username ],
        [ password => $self->password ],
        [ database => $uri->dbname    ],
        [ host     => $uri->host      ],
    ) {
        push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
    }

    # Add variables, if any.
    if (my %vars = $self->variables) {
        push @ret => map {; "--param_$_" => $vars{$_} } sort keys %vars;
    }

    # Options to keep things quiet.
    push @ret => (
        '--progress'       => 'off',
        '--progress-table' => 'off',
        '--disable_suggestion',
    );

    # Add relevant query args.
    my $have_port = $self->_clickcnf->{port} || 0;
    if (my @p = $uri->query_params) {
        while (@p) {
            my ($k, $v) = (lc shift @p, shift @p);
            if ($k eq 'sslmode') {
                # Prefer secure connectivity if SSL mode specified.
                push @ret => '--secure';
            } elsif ($k eq 'nativeport') {
                # Custom config to set the CLI port, which is different
                # from the HTTP port used by the ODBC driver.
                push @ret => '--port', $v;
                $have_port = 1;
            }
        }
    }

    # If no port from config or query params, set it to encrypted port
    # 9440 if the URL port is an HTTPS port.
    if (!$have_port) {
        my $http_port = $uri->port;
        push @ret => '--port', 9440 if $http_port == 8443 || $http_port == 443;
    }

    return \@ret;
}

sub cli { @{ shift->_cli } }

sub key    { 'clickhouse' }
sub name   { 'ClickHouse' }
sub driver { 'DBD::ODBC 1.59' }

sub default_client {
    my $self = shift;
    my $ext  = App::Sqitch::ISWIN || $^O eq 'cygwin' ? '.exe' : '';

    # Try to find the client in the path.
    my @names = map { $_ . $ext  } 'clickhouse', 'clickhouse-client';
    for my $dir (File::Spec->path) {
        for my $try ( @names ) {
            my $path = file $dir, $try;
            # GetShortPathName returns undef for nonexistent files.
            $path = Win32::GetShortPathName($path) // next if App::Sqitch::ISWIN;
            return $try if -f $path && -x $path;
        }
    }

    hurl clickhouse => __x(
        'Unable to locate {cli} client; set "engine.{eng}.client" via sqitch config',
        cli => 'clickhouse',
        eng => 'clickhouse',
    );
}

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
    no utf8;
    return [] unless $_[1];
    my $list = eval $_[1];
    return [] unless $list;
    shift @{ $list } if @{ $list } && $list->[0] eq '';
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
    );

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
supports ClickHouse v25.8 and higher.

=head1 Interface

=head2 Instance Methods

=head3 C<cli>

Returns a list containing the C<clickhouse> client and options to be passed to it.
Used internally when executing scripts.
L<Query parameters|https://github.com/clickHouse/clickhouse-odbc> in the URI
that map to C<clickhouse> client options will be passed to the client, as
follows:

=over

=item * C<SSLMode>: C<--secure>

Assume that TLS is required in the client if SSLMode is set.

=item * C<NativePort>: C<--port>

Sqitch-specific parameter for the client port. Required because the
ODBC driver uses the HTTP ports (8123 or 8443 with C<SSLMode>) while the
ClickHouse CLI uses the Native Protocol port (9000 or 9440 with C<SSLMode>).
Use this option to specify an alternative port for the CLI. See
L<Network Ports|https://clickhouse.com/docs/guides/sre/network-ports> for
additional information.

=back

=head3 C<username>

=head3 C<password>

Overrides the methods provided by the target so that, if the target has
no username or password, Sqitch can look them up in a configuration file
(although it does not yet do so).

=head3 C<uri>

Returns the L<URI> used to connect to the database. It modifies the URI as
follows:

=over

=item hostname

If the host name is not set, sets it from the C<$CLICKHOUSE_HOSTNAME>
environment variable or the hostname read from the ClickHouse configuration
file.

=item port

If the port is not set but the configuration file specifies port C<9440>, assume
the HTTP port should also be secure and set it to C<8443>.

=item database

If the database name is not set, sets it from the C<database> parameter read
from the ClickHouse configuration file.

=item query

Sets ODBC L<query parameters|https://github.com/clickHouse/clickhouse-odbc>
based on the C<$.openSSL.client> parameters from the ClickHouse configuration
file as follows:

=over

=item C<privateKeyFile>: C<PrivateKeyFile>

Path to private key file. Raises an error if both are set and not the same
value.

=item C<certificateFile>: C<CertificateFile>

Path to certificate file. Raises an error if both are set and not the same
value.

=item C<caConfig>: C<CALocation>

Path to the file or directory containing the CA/root certificates. Raises an
error if both are set and not the same value.

=item C<secure>, C<port>, C<host>, C<verificationMode>: C<SSLMode>

Sets the ODBC C<SSLMode> parameter to C<require> when the C<secure> parameter
from the configuration file is true or the port is C<9440>, or the host name
from the configuration file or the target ends in C<.clickhouse.cloud>. If
none of those are true but C<verificationMode> is set, set the C<SSLMode>
query parameters as follows:

   verificationMode | SSLMode
  ------------------|-----------
   none             | [not set]
   relaxed          | allow
   strict           | require
   once             | require

=back

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2026 David E. Wheeler, 2012-2021 iovation Inc.

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
