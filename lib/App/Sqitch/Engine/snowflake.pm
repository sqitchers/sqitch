package App::Sqitch::Engine::snowflake;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use POSIX;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Types qw(DBH ArrayRef HashRef URIDB Str);

extends 'App::Sqitch::Engine';

our $VERSION = '0.9998';

sub key    { 'snowflake' }
sub name   { 'Snowflake' }
sub driver { 'DBD::ODBC 1.43' }
sub default_client { 'snowsql' }

sub destination {
    my $self = shift;
    # Just use the target name if it doesn't look like a URI.
    return $self->target->name if $self->target->name !~ /:/;

    # Use the URI sans password.
    my $uri = $self->target->uri->clone;
    $uri->password(undef) if $uri->password;
    return $uri->as_string;
}

has _snowsql => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;
        my @ret  = ( $self->client );
        for my $spec (
            [ accountname => $self->account ],
            [ username    => $uri->user     ],
            [ dbname      => $uri->dbname   ],
        ) {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        if (my %vars = $self->variables) {
            push @ret => map {; '--variable', "$_=$vars{$_}" } sort keys %vars;
        }

        push @ret => $self->_client_opts;
        return \@ret;
    },
);

sub snowsql { @{ shift->_snowsql } }

has _snowcfg => (
    is      => 'rw',
    isa     => HashRef,
    default => sub {
        require File::HomeDir;
        my $hd = File::HomeDir->my_home or return {};
        require File::Spec;
        my $fn = File::Spec->catfile($hd, '.snowsql', 'config');
        return {} unless -e $fn;
        require Config::GitLike;
        my $data = Config::GitLike->load_file($fn);
        my $cfg = {};
        for my $k (keys %{ $data }) {
            # We only want the default connections config. No named config.
            # (For now, anyway; maybe use database as config name laster?)
            next unless $k =~ /\Aconnections[.]([^.]+)\z/;
            $cfg->{$1} = $data->{$k};
        }
        return $cfg;
    },
);

has uri => (
    is => 'ro',
    isa => URIDB,
    default => sub {
        my $self = shift;
        my $uri  = $self->SUPER::uri;

        # Set defaults in the URI.
        $uri->host($self->_host)       if !$uri->host;
        $uri->port($ENV{SNOWSQL_PORT}) if !$uri->_port && $ENV{SNOWSQL_PORT};
        $uri->user($self->username)    if !$uri->user;
        if (!$uri->password && (my $pw = $self->password)) {
            $uri->password($pw);
        }
        $uri->dbname($ENV{SNOWSQL_DATABASE} || $uri->user) if !$uri->dbname;
        return $uri;
    },
);

sub username {
    my $self = shift;
    return  $self->SUPER::username
        || $ENV{SNOWSQL_USER}
        || $self->_snowcfg->{username}
        || $self->sqitch->sysuser,
}

sub password {
    my $self = shift;
    return $self->SUPER::password
        || $self->target->password
        || $ENV{SNOWSQL_PWD}
        || $self->_snowcfg->{password};
}

sub _account {
    my ($self, $uri) = @_;
    if (my $host = $uri->host) {
        # <account_name>.<region_id>.snowflakecomputing.com
        $host =~ s/[.].+//;
        return $host;
    }
    return $ENV{SNOWSQL_ACCOUNT} || $self->_snowcfg->{accountname} || hurl engine => __(
        'Cannot determine Snowflake account name'
    );
}

sub account {
    my $self = shift;
    $self->_account($self->uri);
}

sub _host {
    my $self = shift;
    my $uri = $self->SUPER::uri;
    if (my $host = $uri->host) {
        # Allow host to just be account name or account + region.
        return $host if $host =~ /\.snowflakecomputing\.com$/;
        return $host . ".snowflakecomputing.com";
    }
    return $ENV{SNOWSQL_HOST} || do {
        join '.', (
            $self->_account($uri),
            (grep { $_ } $self->_snowcfg->{region}),
            'snowflakecomputing.com',
        );
    };
}

has warehouse => (
    is      => 'ro',
    isa     => Str,
    default => sub {
        my $uri = shift->uri;
        require URI::QueryParam;
        $uri->query_param('warehouse') || 'sqitch';
    },
);

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;
        my $uri = $self->uri;
        my $wh = $self->warehouse;
        DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            odbc_utf8_on      => 1,
            FetchHashKeyName  => 'NAME_lc',
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks         => {
                connected => sub {
                    my $dbh = shift;
                    try {
                        $dbh->do($_) for (
                            "ALTER WAREHOUSE $wh RESUME IF SUSPENDED",
                            "USE WAREHOUSE $wh",
                            'USE SCHEMA ' . $self->registry,
                            'ALTER SESSION SET TIMESTAMP_TYPE_MAPPING=TIMESTAMP_LTZ',
                            "ALTER SESSION SET TIMESTAMP_OUTPUT_FORMAT='YYYY-MM-DD HH24:MI:SS'",
                            "ALTER SESSION SET TIMEZONE='UTC'",
                        );
                        $dbh->set_err(undef, undef) if $dbh->err;
                    };
                    return;
                },
                disconnect => sub {
                    shift->do("ALTER WAREHOUSE $wh SUSPEND");
                    return;
                },
            },
        });
    }
);

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

sub _client_opts {
    return (
        '--noup',
        '--option' => 'auto_completion=false',
        '--option' => 'echo=false',
        '--option' => 'execution_only=false',
        '--option' => 'friendly=false',
        '--option' => 'header=false',
        '--option' => 'exit_on_error=true',
        '--option' => 'output_format=plain',
        '--option' => 'paging=false',
        '--option' => 'timing=false',
        '--option' => 'wrap=false',
        '--option' => 'results=true',
        '--option' => 'rowset_size=1000',
        '--option' => 'syntax_style=default',
        '--option' => 'variable_substitution=true',
        '--variable' => 'registry=' . $_[0]->registry,
        '--variable' => 'warehouse=' . $_[0]->warehouse,
    );
}

sub _listagg_format {
    return q{listagg(%s, ' ')};
}

sub _ts_default { 'current_timestamp' }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT true
          FROM information_schema.tables
         WHERE TABLE_CATALOG = current_database()
           AND TABLE_SCHEMA  = UPPER(?)
           AND TABLE_NAME    = UPPER(?)
     }, undef, $self->registry, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->registry;
    hurl engine => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $schema
    ) if $self->initialized;

    $self->run_file( file(__FILE__)->dir->file('snowflake.sql') );
    $self->dbh->do("USE SCHEMA $schema");
    $self->_register_release;
}

sub _no_table_error  {
    return $DBI::state && $DBI::state eq '02000'; # ERRCODE_UNDEFINED_TABLE
}

sub _no_column_error  {
    return $DBI::state && $DBI::state eq '42703'; # ERRCODE_UNDEFINED_COLUMN
}

sub _ts2char_format {
    qq{to_varchar(CONVERT_TIMEZONE('UTC', %s), '"year:"YYYY":month:"MM":day:"DD":hour:"HH24":minute:"MI":second:"SS":time_zone:UTC"')};
}



sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _regex_op { 'REGEXP' }

sub _simple_from { ' FROM dual' }


sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    my $offset_expr = $offset ? " OFFSET $offset" : '';
    return try {
        $self->dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1$offset_expr
        }, undef, $project || $self->plan->project)->[0];
    } catch {
        return if $self->_no_table_error && !$self->initialized;
        die $_;
    };
}

sub is_deployed_change {
    my ( $self, $change ) = @_;
    $self->dbh->selectcol_arrayref(q{
        SELECT true
          FROM changes
         WHERE change_id = ?
    }, undef, $change->id)->[0];
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->dbh->selectcol_arrayref(q{
        SELECT true
          FROM tags
         WHERE tag_id = ?
    }, undef, $tag->id)->[0];
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    # NOTE: Query from DBIEngine doesn't work in Snowflake:
    #   SQL compilation error: Unsupported subquery type cannot be evaluated (SQL-42601)
    # Looks like it doesn't yet support correlated subqueries.
    # https://docs.snowflake.net/manuals/sql-reference/operators-subquery.html
    # The CTE-based query borrowed from Exasol seems to be fine, however.
    return @{ $self->dbh->selectall_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT c.change_id, c.project, c.change, t.tag AS asof_tag
          FROM dependencies d
          JOIN changes  c ON c.change_id = d.change_id
          LEFT JOIN tag t ON t.project   = c.project AND t.committed_at >= c.committed_at
         WHERE d.dependency_id = ?
           AND (t.rnk IS NULL OR t.rnk = 1)
    }, { Slice => {} }, $change->id) };
}

sub name_for_change_id {
    my ( $self, $change_id ) = @_;
    # NOTE: Query from DBIEngine doesn't work in Snowflake:
    #   SQL compilation error: Unsupported subquery type cannot be evaluated (SQL-42601)
    # Looks like it doesn't yet support correlated subqueries.
    # https://docs.snowflake.net/manuals/sql-reference/operators-subquery.html
    # The CTE-based query borrowed from Exasol seems to be fine, however.
    return $self->dbh->selectcol_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT change || COALESCE(t.tag, '@HEAD')
          FROM changes c
          LEFT JOIN tag t ON c.project = t.project AND t.committed_at >= c.committed_at
         WHERE change_id = ?
           AND (t.rnk IS NULL OR t.rnk = 1)
    }, undef, $change_id)->[0];
}

sub _limit_offset {
    # LIMIT/OFFSET don't support parameters, alas. So just put them in the query.
    my ($self, $lim, $off)  = @_;
    return ['LIMIT ' . ($lim || POSIX::INT_MAX), "OFFSET $off"] if $off;
    return ["LIMIT $lim"] if $lim;
    return;
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--option' => 'quiet=true', '--filename' => $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->snowsql, @_ );
    # Does not override connection config, alas.
    local $ENV{SNOWSQL_PWD} = $pass;
    return $sqitch->run( $self->snowsql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->snowsql, @_ );
    local $ENV{SNOWSQL_PWD} = $pass;
    return $sqitch->capture( $self->snowsql, @_ );
}

sub _probe {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->probe( $self->snowsql, @_ );
    local $ENV{SNOWSQL_PWD} = $pass;
    return $sqitch->probe( $self->snowsql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->spool( $fh, $self->snowsql, @_ );
    local $ENV{SNOWSQL_PWD} = $pass;
    return $sqitch->spool( $fh, $self->snowsql, @_ );
}

1;

__END__

=head1 Name

App::Sqitch::Engine::snowflake - Sqitch Snowflake Engine

=head1 Synopsis

  my $snowflake = App::Sqitch::Engine->load( engine => 'snowflake' );

=head1 Description

App::Sqitch::Engine::snowflake provides the Snowflake storage engine for Sqitch.

=head1 Interface

=head2 Attributes

=head3 C<account>

Returns the Snowflake account name, or an exception if none can be determined.
Sqitch looks for the account code in this order:

=over

=item 1

In the host name of the target URI.

=item 2

In the C<$SNOWSQL_ACCOUNT> environment variable.

=item 3

In the C<connections.accountname> setting in the
L<SnowSQL configuration file|https://docs.snowflake.net/manuals/user-guide/snowsql-start.html#configuring-default-connection-settings>.

=back

=head3 C<warehouse>

Returns the warehouse to use for all connections. Defaults to the value of the
C<warehouse> query parameter of the target URI, or else "sqitch". This value
will be available to all Snowflake change scripts as the C<&warehouse>
variable.

=head2 Instance Methods

=head3 C<initialized>

  $snowflake->initialize unless $snowflake->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $snowflake->initialize;

Initializes a database for Sqitch by installing the Sqitch registry schema.

=head3 C<snowsql>

Returns a list containing the C<snowsql> client and options to be passed to
it. Used internally when executing scripts.

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
