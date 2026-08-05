package App::Sqitch::Engine::duckdb;

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
use App::Sqitch::Types qw(URIDB DBH ArrayRef);
use namespace::autoclean;

extends 'App::Sqitch::Engine';

# VERSION

has registry_uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri  = $self->uri->clone;
        my $reg  = $self->registry;

        if ( file($reg)->is_absolute ) {
            $uri->dbname($reg);
        } elsif (my @segs = $uri->path_segments) {
            my $bn = file( $segs[-1] )->basename;
            if ($reg =~ /[.]/ || $bn !~ /[.]/) {
                $segs[-1] =~ s/\Q$bn\E$/$reg/;
            } else {
                my ($b, $e) = split /[.]/, $bn, 2;
                $segs[-1] =~ s/\Q$b\E[.]$e$/$reg.$e/;
            }
            $uri->path_segments(@segs);
        } else {
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

sub key    { 'duckdb' }
sub name   { 'DuckDB' }
sub driver { 'DBD::DuckDB 0.16' }
sub default_client { 'duckdb' }
sub _dsn { shift->registry_uri->dbi_dsn }

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        my $dbh = DBI->connect($self->_dsn, '', '', {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            HandleError       => $self->error_handler,
        });

        return $dbh;
    }
);

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

has _duckdb => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $dbname = $self->uri->dbname
            or hurl duckdb => __x(
                'Database name missing in URI {uri}',
                uri => $self->uri,
            );

        return [
            $self->client,
            '-noheader',
            '-csv',
            '-batch',
            $dbname,
        ];
    },
);

sub duckdb { @{ shift->_duckdb } }

sub _version_query { 'SELECT CAST(ROUND(MAX(version), 1) AS VARCHAR) FROM releases' }

sub _initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1 FROM information_schema.tables WHERE table_name = ?
        )
    }, undef, 'changes')->[0];
}

sub _initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->registry_uri->dbname,
    ) if $self->initialized;

    my @cmd = $self->duckdb;
    $cmd[-1] = $self->registry_uri->dbname;
    $self->sqitch->run( @cmd, '-f',
        file(__FILE__)->dir->file('duckdb.sql') );
    $self->_register_release;
}

sub _no_table_error  {
    return $DBI::errstr && $DBI::errstr =~ /^Catalog Error: Table with name/;
}

sub _no_column_error  {
    return $DBI::errstr && $DBI::errstr =~ /^Binder Error: No column named/;
}

sub _unique_error  {
    return $DBI::errstr && $DBI::errstr =~ /^Constraint Error: Duplicate key/;
}

sub _regex_op { 'REGEXP_MATCHES' }

sub _regex_expr {
    my ( $self, $col, $regex ) = @_;
    return "REGEXP_MATCHES($col, ?)", $regex;
}

sub _limit_default { -1 }

sub _ts_default {
    q{current_timestamp};
}

sub _ts2char_format {
    return q{strftime('year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%M:second:%%S:time_zone:UTC', %s)};
}

sub _listagg_format {
    return q{group_concat(%s, ' ')};
}

sub _char2ts {
    my $dt = $_[1];
    $dt->set_time_zone('UTC');
    return join ' ', $dt->ymd('-'), $dt->hms(':');
}

sub _run {
    my $self   = shift;
    return $self->sqitch->run( $self->duckdb, @_ );
}

sub _capture {
    my $self   = shift;
    return $self->sqitch->capture( $self->duckdb, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    return $self->sqitch->spool( $fh, $self->duckdb, @_ );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run( '-f', $file );
}

sub run_verify {
    my ($self, $file) = @_;
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( '-f', $file );
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub run_upgrade {
    my ($self, $file) = @_;
    my @cmd = $self->duckdb;
    $cmd[-1] = $self->registry_uri->dbname;
    return $self->sqitch->run( @cmd, '-f', $file );
}

1;

__END__

=head1 Name

App::Sqitch::Engine::duckdb - Sqitch DuckDB Engine

=head1 Synopsis

  my $duckdb = App::Sqitch::Engine->load( engine => 'duckdb' );

=head1 Description

App::Sqitch::Engine::duckdb provides the DuckDB storage engine for Sqitch.

=head1 Interface

=head2 Accessors

=head3 C<client>

Returns the path to the DuckDB client.

=head2 Instance Methods

=head3 C<duckdb>

Returns a list containing the C<duckdb> client and options to be passed to it.
Used internally when executing scripts.

=head1 Author

Paul Monson <pmon@pmonson.com>

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
