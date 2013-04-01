package App::Sqitch::Engine::sqlite;

use 5.010;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use App::Sqitch::DateTime;
use Path::Class;
use Mouse;
use namespace::autoclean;

extends 'App::Sqitch::Engine';

our $VERSION = '0.954';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.sqlite.client' )
            || 'sqlite3' . ( $^O eq 'MSWin32' ? '.exe' : '' );
    },
);

has db_name => (
    is       => 'ro',
    isa      => 'Maybe[Path::Class::File]',
    lazy     => 1,
    required => 1,
    handles  => { destination => 'stringify' },
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        my $name = $sqitch->db_name
            || $self->sqitch->config->get( key => 'core.sqlite.db_name' )
            || try { $sqitch->plan->project . '.db' }
            || return undef;
        return file $name;
    },
);

has sqitch_db => (
    is       => 'ro',
    isa      => 'Maybe[Path::Class::File]',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        if (my $db = $self->sqitch->config->get( key => 'core.sqlite.sqitch_db' ) ) {
            return file $db;
        }
        if (my $db = $self->db_name) {
            return $db->dir->file('sqitch.db');
        }
        return undef;
    },
);

has _dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        eval "require DBD::SQLite";
        hurl sqlite => __ 'DBD::SQLite module required to manage PostgreSQL' if $@;

        my $dsn = 'dbi:SQLite:dbname=' . ($self->sqitch_db || hurl sqlite => __(
            'No database specified; use --db-name set "ore.sqlite.db_name" via sqitch config'
        ));

        DBI->connect($dsn, '', '', {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            sqlite_unicode    => 1,
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks         => {
                connected => sub {
                    my $dbh = shift;
                    $dbh->do('PRAGMA foreign_keys = ON');
                    return;
                },
            },
        });
    }
);

has sqlite3 => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        return [
            $self->client,
            '-noheader',
            '-bail',
            '-csv', # or -column or -line?
            $self->db_name
        ];
    },
);

sub config_vars {
    return (
        client    => 'any',
        db_name   => 'any',
        sqitch_db => 'any',
    );
}

sub begin_work {
    my $self = shift;
    $self->_dbh->do('BEGIN EXCLUSIVE TRANSACTION');
    return $self;
}

sub initialized {
    my $self = shift;
    return $self->_dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?
        )
    }, undef, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    hurl sqlite => __x(
        'Sqitch database {database} already initialized',
        database => $self->sqitch_db,
    ) if $self->initialized;

    # Load up our database.
    my @cmd = $self->sqlite3;
    $cmd[-1] = $self->sqitch_db;
    my $file = file(__FILE__)->dir->file('sqlite.sql');
    $self->sqitch->run( @cmd, '.read ' . $self->_dbh->quote($file) );
}

sub _regex_op { 'REGEXP' }

sub _ts2char_format {
    return q{strftime('year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%M:second:%%S:time_zone:UTC', %s)};
}

sub _listagg_format {
    return q{group_concat(%s, ', ')};
}

sub _char2ts {
    my $dt = $_[1];
    $dt->set_time_zone('UTC');
    return join ' ', $dt->ymd('-'), $dt->hms(':');
}

sub _run {
    my $self   = shift;
    return $self->sqitch->run( $self->sqlite3, @_ );
}

sub _capture {
    my $self   = shift;
    return $self->sqitch->capture( $self->sqlite3, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    return $self->sqitch->spool( $fh, $self->sqlite3, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run( '.read ' . $self->_dbh->quote($file) );
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '.read ' . $self->_dbh->quote($file) );
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

__PACKAGE__->meta->make_immutable;
with 'App::Sqitch::Role::DBIEngine';
no Mouse;

1;

__END__

=head1 Name

App::Sqitch::Engine::sqlite - Sqitch SQLite Engine

=head1 Synopsis

  my $sqlite = App::Sqitch::Engine->load( engine => 'sqlite' );

=head1 Description

App::Sqitch::Engine::sqlite provides the SQLite storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::sqlite->config_vars;

Returns a hash of names and types to use for variables in the C<core.sqlite>
section of the a Sqitch configuration file. The variables and their types are:

  client    => 'any'
  db_name   => 'any'
  sqitch_db => 'any'

=head2 Accessors

=head3 C<client>

Returns the path to the SQLite client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.sqlite.client> configuration value, or else defaults to C<sqlite3> (or
C<sqlite3.exe> on Windows), which should work if it's in your path.

=head3 C<db_name>

Returns the name of the database file. If C<--db-name> was passed to C<sqitch>
that's what will be returned.

=head3 C<sqitch_db>

Name of the SQLite database file to use for the Sqitch metadata tables.
Returns the value of the C<core.sqlite.sqitch_db> configuration value, or else
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
