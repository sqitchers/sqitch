package App::Sqitch::Engine::pg;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use List::Util qw(first);
use App::Sqitch::Types qw(DBH ArrayRef);
use Type::Utils qw(enum);
use namespace::autoclean;

extends 'App::Sqitch::Engine';

# VERSION

sub destination {
    my $self = shift;

    # Just use the target name if it doesn't look like a URI or if the URI
    # includes the database name.
    return $self->target->name if $self->target->name !~ /:/
        || $self->target->uri->dbname;

    # Use the URI sans password, and with the database name added.
    my $uri = $self->target->uri->clone;
    $uri->password(undef) if $uri->password;
    $uri->dbname(
        $ENV{PGDATABASE}
        || $self->username
        || $ENV{PGUSER}
        || $self->sqitch->sysuser
    );
    return $uri->as_string;
}

# DBD::pg and psql use fallbacks consistently, thanks to libpq. These include
# environment variables, system info (username), the password file, and the
# connection service file. Best for us not to second-guess these values,
# though we admittedly try when setting the database name in the destination
# URI for unnamed targets a few lines up from here.
sub _def_user { }
sub _def_pass { }

has _psql => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;
        my @ret  = ( $self->client );

        my %query_params = $uri->query_params;
        my @conninfo;
        for my $spec (
            [ user   => $self->username ],
            [ dbname => $uri->dbname    ],
            [ host   => $uri->host      ],
            [ port   => $uri->port      ],
            map { [ $_ => $query_params{$_} ] }
                sort keys %query_params,
        ) {
            next unless defined $spec->[1] && length $spec->[1];
            if ($spec->[1] =~ /[ "'\\]/) {
                $spec->[1] =~ s/([ "'\\])/\\$1/g;
            }
            push @conninfo, "$spec->[0]=$spec->[1]";
        }

        push @ret => '--dbname', join ' ', @conninfo if @conninfo;

        if (my %vars = $self->variables) {
            push @ret => map {; '--set', "$_=$vars{$_}" } sort keys %vars;
        }

        push @ret => $self->_client_opts;
        return \@ret;
    },
);

sub _client_opts {
    my $self = shift;
    return (
        '--quiet',
        '--no-psqlrc',
        '--no-align',
        '--tuples-only',
        '--set' => 'ON_ERROR_STOP=1',
        '--set' => 'registry=' . $self->registry,
    );
}

sub psql { @{ shift->_psql } }

sub key    { 'pg' }
sub name   { 'PostgreSQL' }
sub driver { 'DBD::Pg 2.0' }
sub default_client { 'psql' }

has _provider => (
    is      => 'rw',
    isa     => enum([qw( postgres yugabyte )]),
    default => 'postgres',
    lazy    => 1,
);

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        my $uri = $self->uri;
        local $ENV{PGCLIENTENCODING} = 'UTF8';
        DBI->connect($uri->dbi_dsn, $self->username, $self->password, {
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
                    my $dbh = shift;
                    $dbh->do('SET client_min_messages = WARNING');
                    try {
                        $dbh->do(
                            'SET search_path = ?',
                            undef, $self->registry
                        );
                        # https://www.nntp.perl.org/group/perl.dbi.dev/2013/11/msg7622.html
                        $dbh->set_err(undef, undef) if $dbh->err;
                    };
                    # Determine the provider. Yugabyte says this is the right way to do it.
                    # https://yugabyte-db.slack.com/archives/CG0KQF0GG/p1653762283847589
                    my $v = $dbh->selectcol_arrayref(
                        q{SELECT split_part(version(), ' ', 2)}
                    )->[0] // '';
                    $self->_provider('yugabyte') if $v =~ /-YB-/;
                    return;
                },
            },
        });
    }
);

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

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

sub _ts_default { 'clock_timestamp()' }

sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _listagg_format {
    my $dbh = shift->dbh;
    # Since 9.3, we can use array_remove().
    return q{array_remove(array_agg(%1$s ORDER BY %1$s), NULL)}
        if $dbh->{pg_server_version} >= 90300;

    # Since 8.4 we can use ORDER BY.
    return q{ARRAY(SELECT * FROM UNNEST( array_agg(%1$s ORDER BY %1$s) ) a WHERE a IS NOT NULL)}
        if $dbh->{pg_server_version} >= 80400;

    return q{ARRAY(SELECT * FROM UNNEST( array_agg(%s) ) a WHERE a IS NOT NULL)};
}

sub _regex_op { '~' }

sub _version_query { 'SELECT MAX(version)::TEXT FROM releases' }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE FROM pg_catalog.pg_tables
             WHERE schemaname = ? AND tablename = ?
        )
    }, undef, $self->registry, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $self->registry
    ) if $self->initialized;
    $self->_run_registry_file( file(__FILE__)->dir->file($self->key . '.sql') );
    $self->_register_release;
}

sub _psql_major_version {
    my $self = shift;
    my $psql_version = $self->sqitch->probe($self->client, '--version');
    my @parts = split /\s+/, $psql_version;
    my ($maj) = $parts[-1] =~ /^(\d+)/;
    return $maj || 0;
}

sub _run_registry_file {
    my ($self, $file) = @_;
    my $schema = $self->registry;

    # Fetch the client version. 8.4 == 80400
    my $version =  $self->_probe('-c', 'SHOW server_version_num');
    my $psql_maj = $self->_psql_major_version;

    # Is this XC?
    my $opts =  $self->_probe('-c', q{
        SELECT count(*)
          FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON p.pronamespace = n.oid
         WHERE nspname = 'pg_catalog'
           AND proname = 'pgxc_version';
    }) ? ' DISTRIBUTE BY REPLICATION' : '';

    if ($version < 90300 || $psql_maj < 9) {
        # Need to transform the SQL and write it to a temp file.
        my $sql = scalar $file->slurp;

        # No CREATE SCHEMA IF NOT EXISTS syntax prior to 9.3.
        $sql =~ s/SCHEMA IF NOT EXISTS/SCHEMA/ if $version < 90300;
        if ($psql_maj < 9) {
            # Also no :"registry" variable syntax prior to psql 9.0.s
            ($schema) = $self->dbh->selectrow_array(
                'SELECT quote_ident(?)', undef, $schema
            );
            $sql =~ s{:"registry"}{$schema}g;
        }
        require File::Temp;
        my $fh = File::Temp->new;
        print $fh $sql;
        close $fh;
        $self->_run(
            '--file' => $fh->filename,
            '--set'  => "tableopts=$opts",
        );
    } else {
        # We can take advantage of the :"registry" variable syntax.
        $self->_run(
            '--file' => $file,
            '--set'  => "registry=$schema",
            '--set'  => "tableopts=$opts",
        );
    }

    $self->dbh->do('SET search_path = ?', undef, $schema);
}

# Override to lock the changes table. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE')
        if $self->_provider eq 'postgres';
        # Yugabyte does not yet support EXCLUSIVE MODE.
        # https://docs.yugabyte.com/preview/api/ysql/the-sql-language/statements/txn_lock/#lockmode-1
    return $self;
}

# Override to try to acquire a lock on a constant number without waiting.
sub try_lock {
    shift->dbh->selectcol_arrayref(
        'SELECT pg_try_advisory_lock(75474063)'
    )->[0]
}

# Override to try to acquire a lock on a constant number, waiting for the lock
# until timeout.
sub wait_lock {
    my $self = shift;

    # Yugabyte does not support advisory locks.
    # https://github.com/yugabyte/yugabyte-db/issues/3642
    # Use pessimistic locking when it becomes available.
    # https://github.com/yugabyte/yugabyte-db/issues/5680
    return 1 if $self->_provider ne 'postgres';

    # Asynchronously request a lock with an indefinite wait.
    my $dbh = $self->dbh;
    $dbh->do(
        'SELECT pg_advisory_lock(75474063)',
        { pg_async => DBD::Pg::PG_ASYNC() },
    );

    # Use _timeout to periodically check for the result.
    return 1 if $self->_timeout(sub { $dbh->pg_ready && $dbh->pg_result });

    # Timed out, cancel the query and return false.
    $dbh->pg_cancel;
    return 0;
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

sub run_upgrade {
    shift->_run_registry_file(@_);
}

# Override to avoid cast errors, and to use VALUES instead of a UNION query.
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
        } . join( ",\n                ", ( q{(?::text, ?::text, ?::text, ?::text, ?::text, ?::text, ?::text, ?::timestamptz, ?::text, ?::text)} ) x @tags )
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

# Override to take advantage of the RETURNING expression, and to save tags as
# an array rather than a space-delimited string.
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

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _no_table_error  {
    return 0 unless $DBI::state && $DBI::state eq '42P01'; # undefined_table
    my $dbh = shift->dbh;
    return 1 unless $dbh->{pg_server_version} >= 90000;

    # Try to avoid confusion for people monitoring the Postgres error log by
    # sending a warning to the log immediately after the missing relation error
    # to tell log watchers that Sqitch is aware of the issue and will next
    # initialize the database. Hopefully this will reduce confusion and
    # unnecessary time trouble shooting an error that Sqitch handles.
    my @msg = map { $dbh->quote($_) } (
        __ 'Sqitch registry not initialized',
        __ 'Because the "changes" table does not exist, Sqitch will now initialize the database to create its registry tables.',
    );
    $dbh->do(sprintf q{DO $$
        BEGIN
            SET LOCAL client_min_messages = 'ERROR';
            RAISE WARNING USING ERRCODE = 'undefined_table', MESSAGE = %s, DETAIL = %s;
        END;
    $$}, @msg);
    return 1;
}

sub _no_column_error  {
    return $DBI::state && $DBI::state eq '42703'; # undefined_column
}

sub _in_expr {
    my ($self, $vals) = @_;
    return '= ANY(?)', $vals;
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

sub _probe {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->probe( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->probe( $self->psql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->spool( $fh, $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->spool( $fh, $self->psql, @_ );
}

1;

__END__

=head1 Name

App::Sqitch::Engine::pg - Sqitch PostgreSQL Engine

=head1 Synopsis

  my $pg = App::Sqitch::Engine->load( engine => 'pg' );

=head1 Description

App::Sqitch::Engine::pg provides the PostgreSQL storage engine for Sqitch. It
supports PostgreSQL 8.4.0 and higher, Postgres-XC 1.2 and higher, and YugabyteDB.

=head1 Interface

=head2 Instance Methods

=head3 C<initialized>

  $pg->initialize unless $pg->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $pg->initialize;

Initializes a database for Sqitch by installing the Sqitch registry schema.

=head3 C<psql>

Returns a list containing the C<psql> client and options to be passed to it.
Used internally when executing scripts.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2021 iovation Inc., David E. Wheeler

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
