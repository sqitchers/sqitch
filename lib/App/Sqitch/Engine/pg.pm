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

our $VERSION = '0.992';

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
               $ENV{PGDATABASE}
            || $uri->user
            || $ENV{PGUSER}
            || $self->sqitch->sysuser
        ) unless $uri->dbname;
        return $uri->as_string;
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
            '--no-psqlrc',
            '--no-align',
            '--tuples-only',
            '--set' => 'ON_ERROR_ROLLBACK=1',
            '--set' => 'ON_ERROR_STOP=1',
            '--set' => 'registry=' . $self->registry,
            '--set' => 'sqitch_schema=' . $self->registry, # deprecated
        );
        return \@ret;
    },
);

sub key    { 'pg' }
sub name   { 'PostgreSQL' }
sub driver { 'DBD::Pg 2.0' }
sub default_client { 'psql' }

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        my $uri = $self->uri;
        DBI->connect($uri->dbi_dsn, scalar $uri->user, scalar $uri->password, {
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
                    try {
                        $dbh->do(
                            'SET search_path = ?',
                            undef, $self->registry
                        );
                        # http://www.nntp.perl.org/group/perl.dbi.dev/2013/11/msg7622.html
                        $dbh->set_err(undef, undef) if $dbh->err;
                    };
                    return;
                },
            },
            $uri->query_params,
        });
    }
);

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
    q{ARRAY(SELECT * FROM UNNEST( array_agg(%s) ) a WHERE a IS NOT NULL)}
}

sub _regex_op { '~' }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT TRUE FROM pg_catalog.pg_namespace WHERE nspname = ?
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

    my $file = file(__FILE__)->dir->file('pg.sql');

    # Check the client version.
    my ($maj, $min) = split /[.]/ => (
        split / / => $self->sqitch->probe( $self->client, '--version' )
    )[-1];

    if ($maj < 9) {
        # Need to write a temp file; no :"registry" variable syntax.
        ($schema) = $self->dbh->selectrow_array(
            'SELECT quote_ident(?)', undef, $schema
        );
        (my $sql = scalar $file->slurp) =~ s{:"registry"}{$schema}g;
        require File::Temp;
        my $fh = File::Temp->new;
        print $fh $sql;
        close $fh;
        $self->_run( '--file' => $fh->filename );
    } else {
        # We can take advantage of the :"registry" variable syntax.
        $self->_run(
            '--file' => $file,
            '--set'  => "registry=$schema",
        );
    }

    $self->dbh->do('SET search_path = ?', undef, $schema);
    return $self;
}

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

sub _ts2char($) {
    my $col = shift;
    return qq{to_char($col AT TIME ZONE 'UTC', '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _no_table_error  {
    return $DBI::state && $DBI::state eq '42P01'; # undefined_table
}

sub _in_expr {
    my ($self, $vals) = @_;
    return '= ANY(?)', $vals;
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
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->run( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->run( $self->psql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->capture( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->capture( $self->psql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->spool( $fh, $self->psql, @_ );
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

App::Sqitch::Engine::pg provides the PostgreSQL storage engine for Sqitch. It
supports PostgreSQL 8.4.0 and higher.

=head1 Interface

=head2 Instance Methods

=head3 C<initialized>

  $pg->initialize unless $pg->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $pg->initialize;

Initializes a database for Sqitch by installing the Sqitch registry schema.

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
