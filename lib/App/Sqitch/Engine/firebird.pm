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
use Mouse;
use namespace::autoclean;
use List::MoreUtils qw(firstidx);

extends 'App::Sqitch::Engine';
sub dbh; # required by DBIEngine;
with 'App::Sqitch::Role::DBIEngine';

our $VERSION = '0.983';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.firebird.client' )
            || 'isql' . ( $^O eq 'MSWin32' ? '.exe' : '' )
            || 'fbsql' . ( $^O eq 'MSWin32' ? '.exe' : '' );
    },
);

has username => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_username || $sqitch->config->get( key => 'core.firebird.username' );
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.firebird.password' );
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
        $sqitch->db_name || $sqitch->config->get( key => 'core.firebird.db_name' );
    },
);

sub destination { shift->db_name }

has sqitch_db => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.firebird.sqitch_db' ) || 'sqitch';
    },
);

sub meta_destination { shift->sqitch_db }

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_host || $sqitch->config->get( key => 'core.firebird.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_port || $sqitch->config->get( key => 'core.firebird.port' );
    },
);

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { require DBD::Firebird } catch {
            hurl firebird => __ 'DBD::Firebird module required to manage Firebird';
        };

        my $dsn = 'dbi:Firebird:dbname=' . ($self->sqitch_db || hurl firebird => __(
            'No database specified; use --db-name or set "core.firebird.db_name" via sqitch config'
        ));

        $dsn .= join '' => map {
            ";$_->[0]=$_->[1]"
        } grep { $_->[1] } (
            [ host       => $self->host ],
            [ port       => $self->port ],
            [ ib_dialect => 3           ],
            [ ib_charset => 'UTF8'      ],
        );

        my $dbh = DBI->connect($dsn, $self->username, $self->password, {
            PrintError     => 0,
            RaiseError     => 0,
            AutoCommit     => 1,
            ib_enable_utf8 => 1,
            HandleError          => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks             => {
                connected => sub {
                    my $dbh = shift;
                    # $dbh->do("SET SESSION $_") for (
                    #     q{character_set_client   = 'utf8'},
                    #     q{character_set_server   = 'utf8'},
                    #     q{time_zone              = '+00:00'},
                    #     q{group_concat_max_len   = 32768},
                    # );
                    return;
                },
            },
        });

        # Make sure we support this version. ???

        return $dbh;
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
        my @ret  = ( $self->client );
        for my $spec (
            [ host     => $self->host     ],
            [ port     => $self->port     ],
            [ user     => $self->username ],
            [ password => $self->password ],
            [ database => $self->db_name  ],
        ) {
            push @ret, "-$spec->[0]" => $spec->[1] if $spec->[1];
        }

        push @ret => (
            '-bail',
            '-quiet',
            '-sqldialect 3',
            '-pagelength 16384',
        );
        return \@ret;
    },
);

sub config_vars {
    return (
        client    => 'any',
        username  => 'any',
        password  => 'any',
        db_name   => 'any',
        host      => 'any',
        port      => 'int',
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
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->sqitch_db,
    ) if $self->initialized;

    # Create the Sqitch database if it does not exist.
    # From t/TestFirebird.pm:
    # try {
    #     require DBD::Firebird;
    #     DBD::Firebird->create_database(
    #         {   db_path  => $self->sqitch_db,
    #             user     => $self->username,
    #             password => $self->password,

    #             # dialect defaults to 3
    #             character_set => 'UTF8',
    #         }
    #     );
    # }
    # catch {
    #     hurl firebird => __ "DBD::Firebird failed to create test database: $_";
    # };

    # Connect to the Sqitch database.
    my @cmd = $self->isql;
    $cmd[1 + firstidx { $_ eq '-database' } @cmd ] = $self->sqitch_db;
    my $file = file(__FILE__)->dir->file('firebird.sql');

    $self->sqitch->run( @cmd, '-input', "source $file" );
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
    $self->_run( '-input' => "source $file" );
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '-input' => "source $file" );
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
        # Firebird error code 1049 (ER_BAD_DB_ERROR): Unknown database '%-.192s'
        return if $DBI::err == 1049;
        die $_;
    };
}

__PACKAGE__->meta->make_immutable;
no Mouse;

1;

__END__

=head1 Name

App::Sqitch::Engine::firebird - Sqitch Firebird Engine

=head1 Synopsis

  my $firebird = App::Sqitch::Engine->load( engine => 'firebird' );

=head1 Description

App::Sqitch::Engine::firebird provides the Firebird storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::firebird->config_vars;

Returns a hash of names and types to use for variables in the C<core.firebird>
section of the a Sqitch configuration file. The variables and their types are:

  client    => 'any'
  db_name   => 'any'
  sqitch_db => 'any'

=head2 Accessors

=head3 C<client>

Returns the path to the Firebird client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.firebird.client> configuration value, or else defaults to C<firebird> (or
C<firebird.exe> on Windows), which should work if it's in your path.

=head3 C<db_name>

Returns the name of the database file. If C<--db-name> was passed to C<sqitch>
that's what will be returned.

=head3 C<sqitch_db>

Name of the Firebird database file to use for the Sqitch metadata tables.
Returns the value of the C<core.firebird.sqitch_db> configuration value, or else
defaults to F<sqitch.db> in the same directory as C<db_name>.

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
