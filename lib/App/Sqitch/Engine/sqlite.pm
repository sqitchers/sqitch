package App::Sqitch::Engine::sqlite;

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

our $VERSION = '0.996';

sub BUILD {
    my $self = shift;
    my $uri  = $self->uri;
    unless ($uri->dbname) {
        my $sqitch = $self->sqitch;
        # XXX Config var is for backcompat.
        my $name =  $sqitch->config->get( key => 'core.sqlite.db_name' )
            || try { $sqitch->plan->project . '.db' };
        $uri->dbname($name) if $name;
    }
}

has registry_uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri  = $self->uri->clone;
        my $reg  = $self->registry;

        if (my $db = $self->sqitch->config->get( key => 'core.sqlite.sqitch_db' ) ) {
            # ### Deprecated Sqitch database file name.
            $uri->dbname($db);
        } elsif ( file($reg)->is_absolute ) {
            # Just use an absolute path.
            $uri->dbname($reg);
        } elsif (my @segs = $uri->path_segments) {
            # Use the same name, but replace $name.$ext with $reg.$ext.
            my $bn = file( $segs[-1] )->basename;
            if ($reg =~ /[.]/ || $bn !~ /[.]/) {
                $segs[-1] =~ s/\Q$bn\E$/$reg/;
            } else {
                my ($b, $e) = split /[.]/, $bn, 2;
                $segs[-1] =~ s/\Q$b\E[.]$e$/$reg.$e/;
            }
            $uri->path_segments(@segs);
        } else {
            # No known path, so no name.
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

sub key    { 'sqlite' }
sub name   { 'SQLite' }
sub driver { 'DBD::SQLite 1.37' }
sub default_client { 'sqlite3' }

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        my $uri = $self->registry_uri;
        my $dbh = DBI->connect($uri->dbi_dsn, '', '', {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            sqlite_unicode    => 1,
            sqlite_use_immediate_transaction => 1,
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

        # Make sure we support this version.
        my @v = split /[.]/ => $dbh->{sqlite_version};
        hurl sqlite => __x(
            'Sqitch requires SQLite 3.7.11 or later; DBD::SQLite was built with {version}',
            version => $dbh->{sqlite_version}
        ) unless $v[0] > 3 || ($v[0] == 3 && ($v[1] > 7 || ($v[1] == 7 && $v[2] >= 11)));

        return $dbh;
    }
);

# Need to wait until dbh is defined.
with 'App::Sqitch::Role::DBIEngine';

has _sqlite3 => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;

        # Make sure we can use this version of SQLite.
        my @v = split /[.]/ => (
            split / / => $self->sqitch->probe( $self->client, '-version' )
        )[0];
        hurl sqlite => __x(
            'Sqitch requires SQLite 3.3.9 or later; {client} is {version}',
            client  => $self->client,
            version => join( '.', @v)
        ) unless $v[0] > 3 || ($v[0] == 3 && ($v[1] > 3 || ($v[1] == 3 && $v[2] >= 9)));

        my $dbname = $self->uri->dbname or hurl sqlite => __x(
            'Database name missing in URI {uri}',
            uri => $self->uri,
        );

        return [
            $self->client,
            '-noheader',
            '-bail',
            '-batch',
            '-csv', # or -column or -line?
            $dbname,
        ];
    },
);

sub sqlite3 { @{ shift->_sqlite3 } }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?
        )
    }, undef, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->registry_uri->dbname,
    ) if $self->initialized;

    # Load up our database.
    my @cmd = $self->sqlite3;
    $cmd[-1] = $self->registry_uri->dbname;
    my $file = file(__FILE__)->dir->file('sqlite.sql');
    $self->sqitch->run( @cmd, $self->_read($file) );
}

sub _no_table_error  {
    return $DBI::errstr && $DBI::errstr =~ /^\Qno such table:/;
}

sub _regex_op { 'REGEXP' }

sub _limit_default { -1 }

sub _ts_default {
    q{strftime('%Y-%m-%d %H:%M:%f')};
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
    $self->_run( $self->_read($file) );
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( $self->_read($file) );
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _read {
    my $self = shift;
    my $cmd = '.read ' . $self->dbh->quote(shift);
    return $cmd if $^O ne 'MSWin32';
    return $self->sqitch->quote_shell($cmd);
}

1;

1;

__END__

=head1 Name

App::Sqitch::Engine::sqlite - Sqitch SQLite Engine

=head1 Synopsis

  my $sqlite = App::Sqitch::Engine->load( engine => 'sqlite' );

=head1 Description

App::Sqitch::Engine::sqlite provides the SQLite storage engine for Sqitch.

=head1 Interface

=head2 Accessors

=head3 C<client>

Returns the path to the SQLite client. If C<--db-client> was passed to
C<sqitch>, that's what will be returned. Otherwise, it uses the
C<core.sqlite.client> configuration value, or else defaults to C<sqlite3> (or
C<sqlite3.exe> on Windows), which should work if it's in your path.

=head2 Instance Methods

=head3 C<sqlite3>

Returns a list containing the the C<sqlite3> client and options to be passed to
it. Used internally when executing scripts.

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
