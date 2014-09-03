package App::Sqitch::Engine::vertica;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);

extends 'App::Sqitch::Engine::pg';

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

has '+dbh' => (
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
                            'SET search_path = ?',
                            undef, $self->registry
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
    $self->dbh->do('SET search_path = ?', undef, $schema);
    return $self;
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->run( $self->psql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->run( $self->psql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->capture( $self->psql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->capture( $self->psql, @_ );
}

sub _probe {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->probe( $self->psql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->probe( $self->psql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $uri    = $self->uri;
    my $pass   = $uri->password or return $sqitch->spool( $fh, $self->psql, @_ );
    local $ENV{VSQL_PASSWORD} = $pass;
    return $sqitch->spool( $fh, $self->psql, @_ );
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
