package App::Sqitch::Engine::snowflake;

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

our $VERSION = '0.9998';

sub key    { 'snowflake' }
sub name   { 'Snowflake' }
sub driver { 'DBD::ODBC 1.43' }
sub default_client { 'snowsql' }

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
           $ENV{SNOWSQL_DATABASE}
        || $self->username
        || $ENV{SNOWSQL_USER}
        || $self->sqitch->sysuser
    );
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
            [ username => $self->username ],
            [ dbname   => $uri->dbname    ],
            [ host     => $uri->host      ],
            [ port     => $uri->_port     ],
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

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;

        # Set defaults in the URI.
        my $target = $self->target;
        my $uri = $self->uri;
        # https://my.snowflake.com/docs/5.1.6/HTML/index.htm#2736.htm
        $uri->dbname($ENV{SNOWSQL_DATABASE}) if !$uri->dbname && $ENV{SNOWSQL_DATABASE};
        $uri->host($ENV{SNOWSQL_HOST})       if !$uri->host   && $ENV{SNOWSQL_HOST};
        $uri->port($ENV{SNOWSQL_PORT})       if !$uri->_port  && $ENV{SNOWSQL_PORT};
        $uri->user($ENV{SNOWSQL_USER})       if !$uri->user   && $ENV{SNOWSQL_USER};
        $uri->password($target->password || $ENV{SNOWSQL_PWD})
            if !$uri->password && ($target->password || $ENV{SNOWSQL_PWD});

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
                        $dbh->do($_) for (
                            'USE SCHEMA ' . $dbh->quote($self->registry),
                            'ALTER SESSION SET TIMESTAMP_TYPE_MAPPING=TIMESTAMP_LTZ',
                            "ALTER SESSION SET TIMESTAMP_OUTPUT_FORMAT='YYYY-MM-DD HH24:MI:SS'",
                            "ALTER SESSION SET TIMEZONE='UTC'",
                        );
                        $dbh->set_err(undef, undef) if $dbh->err;
                    };
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
        '--variable' => 'registry=' . shift->registry,
    );
}

sub _listagg_format {
    return q{arrayagg(%s)};
    # return q{listagg(%s, ' ')};
}

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT true
              FROM information_schema.tables
             WHERE TABLE_CATALOG = current_database()
               AND TABLE_SCHEMA  = ?
               AND TABLE_NAME    = ?
        )
    }, undef, $self->registry, 'changes')->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->registry;
    hurl engine => __x(
        'Sqitch schema "{schema}" already exists',
        schema => $schema
    ) if $self->initialized;

    $self->_run_registry_file( file(__FILE__)->dir->file('snowflake.sql') );
    $self->dbh->do('USE SCHEMA ' . $self->dbh->quote($schema));
    $self->_register_release;
}

sub _no_table_error  {
    return $DBI::state && $DBI::state eq '42V01'; # ERRCODE_UNDEFINED_TABLE
}

sub _no_column_error  {
    return $DBI::state && $DBI::state eq '42703'; # ERRCODE_UNDEFINED_COLUMN
}

sub _ts2char_format {
    qq{to_varchar(CONVERT_TIMEZONE('UTC', %s), '"year":YYYY:"month":MM:"day":DD:"hour":HH24:"minute":MI:"second":SS:"time_zone":"UTC"')};
}

sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _regex_op { 'REGEXP_LIKE' }

sub _simple_from { ' FROM dual' }

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--filename' => $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->snowsql, @_ );
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
It supports Snowflake 6.

=head1 Interface

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
