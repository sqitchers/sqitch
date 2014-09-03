package App::Sqitch::Engine::vertica;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Types qw(DBH ArrayRef);

extends 'App::Sqitch::Engine';

our $VERSION = '0.996';

sub key    { 'vertica' }
sub name   { 'Vertica' }
sub driver { 'DBD::Pg 2.0' }
sub default_client { 'vsql' }

has '+destination' => (
    default  => sub {
        my $self = shift;

        # Just use the target unless it looks like a URI.
        my $target = $self->target;
        return $target if $target !~ /:/;

        # Use the URI sans password, and with the database name added.
        my $uri = $self->uri->clone;
        $uri->password(undef) if $uri->password;
        $uri->dbname(
               $ENV{VSQL_DATABASE}
            || $uri->user
            || $ENV{VSQL_USER}
            || $self->sqitch->sysuser
        ) unless $uri->dbname;
        return $uri->as_string;
    },
);

has _vsql => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;
        my @ret  = ( $self->client );
        for my $spec (
            [ username => $uri->user   ],
            [ dbname   => $uri->dbname ],
            [ host     => $uri->host   ],
            [ port     => $uri->_port  ],
            )
        {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        if (my %vars = $self->variables) {
            push @ret => map {; '--set', "$_=$vars{$_}" } sort keys %vars;
        }

        push @ret => (
            '--quiet',
            '--no-vsqlrc',
            '--no-align',
            '--tuples-only',
            '--set' => 'ON_ERROR_STOP=1',
            '--set' => 'registry=' . $self->registry,
        );
        return \@ret;
    },
);

sub vsql { @{ shift->_vsql } }

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        # Set defaults in the URI.
        my $uri = $self->uri;
        # https://my.vertica.com/docs/5.1.6/HTML/index.htm#2736.htm
        $uri->dbname($ENV{VSQL_DATABASE})   if !$uri->dbname   && $ENV{VSQL_DATABASE};
        $uri->host($ENV{VSQL_HOST})         if !$uri->host     && $ENV{VSQL_HOST};
        $uri->port($ENV{VSQL_PORT})         if !$uri->_port    && $ENV{VSQL_PORT};
        $uri->user($ENV{VSQL_USER})         if !$uri->user     && $ENV{VSQL_USER};
        $uri->password($ENV{VSQL_PASSWORD}) if !$uri->password && $ENV{VSQL_PASSWORD};

        DBI->connect($uri->dbi_dsn, scalar $uri->user, scalar $uri->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            odbc_utf8_on      => 1,
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
                        $dbh->do(
                            'SET search_path = ' . $dbh->quote($self->registry)
                        );
                        # http://www.nntp.perl.org/group/perl.dbi.dev/2013/11/msg7622.html
                        $dbh->set_err(undef, undef) if $dbh->err;
                    };
                    return;
                },
            },
        });
    }
);

sub _listagg_format { undef } # Vertica has none!

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

sub _client_opts {
    return (
        '--quiet',
        '--no-vsqlrc',
        '--no-align',
        '--tuples-only',
        '--set' => 'ON_ERROR_STOP=1',
        '--set' => 'registry=' . shift->registry,
    );
}

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE FROM v_catalog.schemata WHERE schema_name = ?
        )
    }, undef, $self->registry)->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->registry;
    hurl engine => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $schema
    ) if $self->initialized;

    my $file = file(__FILE__)->dir->file('vertica.sql');

    # Need to write a temp file; no :"registry" variable syntax.
    ($schema) = $self->dbh->selectrow_array(
        'SELECT quote_ident(?)', undef, $schema
    );
    (my $sql = scalar $file->slurp) =~ s{:"registry"}{$schema}g;
    require File::Temp;
    my $fh = File::Temp->new;
    print $fh $sql;
    close $fh;

    # Now we can execute the file.
    $self->_run( '--file' => $fh->filename );
    $self->dbh->do('SET search_path = ' . $self->dbh->quote($schema));
    return $self;
}

sub _no_table_error  {
    return $DBI::state && $DBI::state eq '42V01'; # ERRCODE_UNDEFINED_TABLE
}

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _multi_values {
    my ($self, $count, $expr) = @_;
    return join "\nUNION ALL ", ("SELECT $expr") x $count;
}

sub _dependency_placeholders {
    return 'CAST(? AS CHAR(40)), CAST(? AS VARCHAR), CAST(? AS VARCHAR), CAST(? AS CHAR(40))';
}

sub _tag_placeholders {
    my $self = shift;
    return join(', ',
        'CAST(? AS CHAR(40))',
        'CAST(? AS VARCHAR)',
        'CAST(? AS VARCHAR)',
        'CAST(? AS CHAR(40))',
        'CAST(? AS VARCHAR)',
        'CAST(? AS VARCHAR)',
        'CAST(? AS VARCHAR)',
        'CAST(? AS TIMESTAMPTZ)',
        'CAST(? AS VARCHAR)',
        'CAST(? AS VARCHAR)',
        $self->_ts_default,
    );
}

sub _tag_subselect_columns {
    my $self = shift;
    return join(', ',
        'CAST(? AS CHAR(40)) AS tid',
        'CAST(? AS VARCHAR) AS tname',
        'CAST(? AS VARCHAR) AS proj',
        'CAST(? AS CHAR(40)) AS cid',
        'CAST(? AS VARCHAR) AS note',
        'CAST(? AS VARCHAR) AS cuser',
        'CAST(? AS VARCHAR) AS cemail',
        'CAST(? AS TIMESTAMPTZ) AS tts',
        'CAST(? AS VARCHAR) AS puser',
        'CAST(? AS VARCHAR) AS pemail',
        $self->_ts_default,
    );
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = sprintf $self->_ts2char_format, 'c.committed_at';
    my $pdtcol = sprintf $self->_ts2char_format, 'c.planned_at';
    my $dbh    = $self->dbh;
    my $state  = $dbh->selectrow_hashref(qq{
        SELECT c.change_id
             , c.change
             , c.project
             , c.note
             , c.committer_name
             , c.committer_email
             , $cdtcol AS committed_at
             , c.planner_name
             , c.planner_email
             , $pdtcol AS planned_at
          FROM changes   c
         WHERE c.project = ?
         ORDER BY c.committed_at DESC
         LIMIT 1
    }, undef, $project // $self->plan->project ) or return undef;
    $state->{tags} = $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ? ORDER BY committed_at',
        undef, $state->{change_id}
    );
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    return $state;
}

sub _deployed_changes {
    my ($self, $sql, @params) = @_;
    my $sth = $self->dbh->prepare($sql);
    $sth->execute(@params);

    my ($last_id, @changes) = ('');
    while (my $res = $sth->fetchrow_hashref) {
        if ($res->{id} eq $last_id) {
            push @{ $changes[-1]->{tags} } => $res->{tag};
        } else {
            $last_id = $res->{id};
            $res->{tags} = [ delete $res->{tag} || () ];
            $res->{timestamp} = _dt $res->{timestamp};
            push @changes => $res;
        }
    }
    return @changes;
}

sub deployed_changes {
    my $self   = shift;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    return $self->_deployed_changes(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               t.tag AS tag
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
         ORDER BY c.committed_at ASC
    }, $self->plan->project);
}

sub deployed_changes_since {
    my ( $self, $change ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    $self->_deployed_changes(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               t.tag AS tag
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
           AND c.committed_at > (SELECT committed_at FROM changes WHERE change_id = ?)
         ORDER BY c.committed_at ASC
    }, $self->plan->project, $change->id);
}

sub load_change {
    my ( $self, $change_id ) = @_;
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';
    my @res = $self->_deployed_changes(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
                t.tag AS tag
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.change_id = ?
    }, $change_id);
    return $res[0];
}

sub change_offset_from_id {
    my ( $self, $change_id, $offset ) = @_;

    # Just return the object if there is no offset.
    return $self->load_change($change_id) unless $offset;

    # Are we offset forwards or backwards?
    my ( $dir, $op ) = $offset > 0 ? ( 'ASC', '>' ) : ( 'DESC' , '<' );
    my $tscol  = sprintf $self->_ts2char_format, 'c.planned_at';

    $offset = abs($offset) - 1;
    my $offset_expr = $offset ? "OFFSET $offset" : '';

    my @res = $self->_deployed_changes(qq{
        SELECT c.change_id AS id, c.change AS name, c.project, c.note,
               $tscol AS "timestamp", c.planner_name, c.planner_email,
               t.tag AS tag
          FROM changes   c
          LEFT JOIN tags t ON c.change_id = t.change_id
         WHERE c.project = ?
           AND c.committed_at $op (
               SELECT committed_at FROM changes WHERE change_id = ?
         )
         ORDER BY c.committed_at $dir
         $offset_expr
    }, $self->plan->project, $change_id);
    return $res[0];
}

sub _ts2char_format {
     q{to_char(%s AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _ts_default { 'clock_timestamp()' }

sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _regex_op { '~' }

# Override to lock the changes table. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock changes to allow only one change at a time.
    $dbh->begin_work;
    $dbh->do('LOCK TABLE changes IN EXCLUSIVE MODE');
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

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;

    my $offexpr = $offset ? " OFFSET $offset" : '';
    return try {
        return $self->dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1$offexpr
        }, undef, $project || $self->plan->project)->[0];
    } catch {
        return if $self->_no_table_error && !$self->initialized;
        die $_;
    };
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    # Why CTE: https://forums.oracle.com/forums/thread.jspa?threadID=1005221
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
    # Why CTE: https://forums.oracle.com/forums/thread.jspa?threadID=1005221
    return $self->dbh->selectcol_arrayref(q{
        WITH tag AS (
            SELECT tag, committed_at, project,
                   ROW_NUMBER() OVER (partition by project ORDER BY committed_at) AS rnk
              FROM tags
        )
        SELECT change || COALESCE(t.tag, '')
          FROM changes c
          LEFT JOIN tag t ON c.project = t.project AND t.committed_at >= c.committed_at
         WHERE change_id = ?
           AND (t.rnk IS NULL OR t.rnk = 1)
    }, undef, $change_id)->[0];
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->run( $self->vsql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->run( $self->vsql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->capture( $self->vsql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->capture( $self->vsql, @_ );
}

sub _probe {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->probe( $self->vsql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->probe( $self->vsql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->spool( $fh, $self->vsql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->spool( $fh, $self->vsql, @_ );
}

1;

__END__

=head1 Name

App::Sqitch::Engine::vertica - Sqitch Vertica Engine

=head1 Synopsis

  my $vertica = App::Sqitch::Engine->load( engine => 'vertica' );

=head1 Description

App::Sqitch::Engine::vertica provides the Vertica storage engine for Sqitch.
It supports Vertica 6.

=head1 Interface

=head2 Instance Methods

=head3 C<initialized>

  $vertica->initialize unless $vertica->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $vertica->initialize;

Initializes a database for Sqitch by installing the Sqitch registry schema.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2014 iovation Inc.

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
