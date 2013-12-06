package App::Sqitch::Engine::mysql;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use Path::Class;
use Mouse;
use namespace::autoclean;
use List::MoreUtils qw(firstidx);

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.990';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.mysql.client' )
            || 'mysql' . ( $^O eq 'MSWin32' ? '.exe' : '' );
    },
);

has sqitch_db => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.mysql.sqitch_db' ) || 'sqitch';
    },
);

has sqitch_db_uri => (
    is       => 'ro',
    isa      => 'URI::db',
    lazy     => 1,
    required => 1,
    handles  => { meta_destination => 'as_string' },
    default  => sub {
        my $self = shift;
        my $uri = $self->db_uri->clone;
        $uri->dbname($self->sqitch_db);
        return $uri;
    },
);

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { require DBD::mysql } catch {
            hurl mysql => __ 'DBD::mysql module required to manage MySQL';
        };

        my $uri = $self->sqitch_db_uri;
        my $dbh = DBI->connect($uri->dbi_dsn, scalar $uri->user, scalar $uri->password, {
            PrintError           => 0,
            RaiseError           => 0,
            AutoCommit           => 1,
            mysql_enable_utf8    => 1,
            mysql_auto_reconnect => 0,
            mysql_use_result     => 0, # Prevent "Commands out of sync" error.
            HandleError          => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks             => {
                connected => sub {
                    my $dbh = shift;
                    $dbh->do("SET SESSION $_") for (
                        q{character_set_client   = 'utf8'},
                        q{character_set_server   = 'utf8'},
                        q{default_storage_engine = 'InnoDB'},
                        q{time_zone              = '+00:00'},
                        q{group_concat_max_len   = 32768},
                        q{sql_mode = '} . join(',', qw(
                            ansi
                            strict_trans_tables
                            no_auto_value_on_zero
                            no_zero_date
                            no_zero_in_date
                            only_full_group_by
                            error_for_division_by_zero
                        )) . q{'},
                    );
                    return;
                },
            },
            $uri->query_params,
        });

        # Make sure we support this version.
        hurl mysql => __x(
            'Sqitch requires MySQL {want_version} or higher; this is {have_version}',
            want_version => '5.6.4',
            have_version => $dbh->selectcol_arrayref('SELECT version()')->[0],
        ) unless $dbh->{mysql_serverversion} >= 50604;

        return $dbh;
    }
);

has mysql => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->db_uri;

        $self->sqitch->warn(__x
            'Database name missing in URI "{uri}"',
            uri => $uri
        ) unless $uri->dbname;

        my @ret  = ( $self->client );
        for my $spec (
            [ user     => $uri->user   ],
            [ database => $uri->dbname ],
            [ host     => $uri->host   ],
            [ port     => $uri->_port  ],
        ) {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        # Special-case --password, which requires = before the value. O_o
        if (my $pw = $uri->password) {
            push @ret, "--password=$pw";
        }

        # if (my %vars = $self->variables) {
        #     push @ret => map {; "--$_", $vars{$_} } sort keys %vars;
        # }

        push @ret => (
            '--skip-pager',
            '--silent',
            '--skip-column-names',
            '--skip-line-numbers',
        );
        return \@ret;
    },
);

sub config_vars {
    return (
        shift->SUPER::config_vars,
        sqitch_db => 'any',
    );
}

sub _char2ts {
    $_[1]->set_time_zone('UTC')->iso8601;
}

sub _ts2char_format {
    return q{date_format(%s, 'year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%i:second:%%S:time_zone:UTC')};
}

sub _ts_default { 'utc_timestamp(6)' }

sub _quote_idents {
    shift;
    map { $_ eq 'change' ? '"change"' : $_ } @_;
}

sub initialized {
    my $self = shift;

    # Try to connect.
    my $err = 0;
    my $dbh = try { $self->dbh } catch { $err = $DBI::err };
    # MySQL error code 1049 (ER_BAD_DB_ERROR): Unknown database '%-.192s'
    return 0 if $err && $err == 1049;

    return $self->dbh->selectcol_arrayref(q{
        SELECT COUNT(*)
          FROM information_schema.tables
         WHERE table_schema = ?
           AND table_name   = ?
    }, undef, $self->sqitch_db, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->sqitch_db,
    ) if $self->initialized;

    # Create the Sqitch database if it does not exist.
    (my $db = $self->sqitch_db) =~ s/"/""/g;
    $self->_run(
        '--execute'  => sprintf(
            'SET sql_mode = ansi; CREATE DATABASE IF NOT EXISTS "%s"',
            $self->sqitch_db
        ),
    );

    # Connect to the Sqitch database.
    my @cmd = $self->mysql;
    $cmd[1 + firstidx { $_ eq '--database' } @cmd ] = $self->sqitch_db;
    my $file = file(__FILE__)->dir->file('mysql.sql');

    $self->sqitch->run( @cmd, '--execute', "source $file" );
}

# Override to lock the Sqitch tables. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock all tables to disallow concurrent changes.
    $dbh->do('LOCK TABLES ' . join ', ', map {
        "$_ WRITE"
    } qw(changes dependencies events projects tags));
    $dbh->begin_work;
    return $self;
}

# Override to unlock the tables, otherwise future transactions on this
# connection can fail.
sub finish_work {
    my $self = shift;
    my $dbh = $self->dbh;
    $dbh->commit;
    $dbh->do('UNLOCK TABLES');
    return $self;
}

sub _no_table_error  {
    return $DBI::errstr =~ /^\Qno such table:/;
}

sub _regex_op { 'REGEXP' }

sub _limit_default { '18446744073709551615' }

sub _listagg_format {
    return q{group_concat(%s SEPARATOR ' ')};
}

sub _run {
    my $self = shift;
    return $self->sqitch->run( $self->mysql, @_ );
}

sub _capture {
    my $self = shift;
    return $self->sqitch->capture( $self->mysql, @_ );
}

sub _spool {
    my $self = shift;
    my $fh   = shift;
    return $self->sqitch->spool( $fh, $self->mysql, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run( '--execute' => "source $file" );
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '--execute' => "source $file" );
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
        # MySQL error code 1049 (ER_BAD_DB_ERROR): Unknown database '%-.192s'
        # MySQL error code 1146 (ER_NO_SUCH_TABLE): Table '%s.%s' doesn't exist
        return if $DBI::err && ($DBI::err == 1049 || $DBI::err == 1146);
        die $_;
    };
}

__PACKAGE__->meta->make_immutable;
no Mouse;

1;

__END__

=head1 Name

App::Sqitch::Engine::mysql - Sqitch MySQL Engine

=head1 Synopsis

  my $mysql = App::Sqitch::Engine->load( engine => 'mysql' );

=head1 Description

App::Sqitch::Engine::mysql provides the MySQL storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::mysql->config_vars;

Returns a hash of names and types to use for variables in the C<core.mysql>
section of the a Sqitch configuration file. The variables and their types are:

  database  => 'any',
  client    => 'any',
  sqitch_db => 'any',

=head2 Accessors

=head3 C<client>

Returns the path to the MySQL client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.mysql.client> configuration value, or else defaults to C<mysql> (or
C<mysql.exe> on Windows), which should work if it's in your path.

=head3 C<sqitch_db>

Name of the MySQL database file to use for the Sqitch metadata tables. Returns
the value of the C<core.mysql.sqitch_db> configuration value, or else defaults
to C<sqitch>.

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
