package App::Sqitch::Engine::oracle;

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

our $VERSION = '0.966';

BEGIN {
    # We tell the Oracle connector which encoding to use. The last part of the
    # environment variable NLS_LANG is relevant concerning data encoding.
    $ENV{NLS_LANG} = 'AMERICAN_AMERICA.AL32UTF8';

    # Disable SQLPATH so that no start scripts run.
    $ENV{SQLPATH} = '';
}

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_client
            || $sqitch->config->get( key => 'core.oracle.client' )
            || file(
                ($ENV{ORACLE_HOME} || ()),
                'sqlplus' . ( $^O eq 'MSWin32' ? '.exe' : '' )
            )->stringify;
    },
);

has username => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_username || $sqitch->config->get( key => 'core.oracle.username' );
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.oracle.password' );
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
        $sqitch->db_name || $sqitch->config->get( key => 'core.oracle.db_name' );
    },
);

has destination => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        $self->db_name
            || $ENV{TWO_TASK}
            || $^O eq 'MSWin32' ? $ENV{LOCAL} : undef
            || $ENV{ORACLE_SID}
    },
);

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_host || $sqitch->config->get( key => 'core.oracle.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->db_port || $sqitch->config->get( key => 'core.oracle.port' );
    },
);

has sqitch_schema => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.oracle.sqitch_schema' )
    },
);

has sqlplus => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        [ $self->client, qw(sqlplus -S -L /nolog) ];
    },
);

has dbh => (
    is      => 'rw',
    isa     => 'DBI::db',
    lazy    => 1,
    default => sub {
        my $self = shift;
        try { require DBD::Oracle } catch {
            hurl oracle => __ 'DBD::Oracle module required to manage Oracle' if $@;
        };

        my $dsn = 'dbi:Oracle:';
        if ($self->host || $self->port) {
            $dsn .=  join ';' => map {
                "$_->[0]=$_->[1]"
            } grep { $_->[1] } (
                [ sid   => $self->destination ],
                [ host  => $self->host        ],
                [ port  => $self->port        ],
            );
        } else {
            $dsn .= $self->destination;
        }

        DBI->connect($dsn, $self->username, $self->password, {
            PrintError        => 0,
            RaiseError        => 0,
            AutoCommit        => 1,
            FetchHashKeyName  => 'NAME_lc',
            HandleError       => sub {
                my ($err, $dbh) = @_;
                $@ = $err;
                @_ = ($dbh->state || 'DEV' => $dbh->errstr);
                goto &hurl;
            },
            Callbacks         => {
                connected => sub {
                    if (my $schema = $self->sqitch_schema) {
                        shift->do('ALTER SESSION SET CURRENT_SCHEMA = ?', undef, $schema);
                    }
                    return;
                },
            },
        });
    }
);

sub config_vars {
    return (
        client        => 'any',
        username      => 'any',
        password      => 'any',
        db_name       => 'any',
        host          => 'any',
        port          => 'int',
        sqitch_schema => 'any',
    );
}

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
     q{to_char(%s AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _ts_default { 'current_timestamp' }

sub _char2ts { $_[1]->as_string(format => 'iso') }

sub _listagg_format {
    q{ARRAY(SELECT * FROM UNNEST( array_agg(%s) ) a WHERE a IS NOT NULL)}
}

sub _regex_op { 'REGEXP_LIKE(%s, ?)' }

sub initialized {
    my $self = shift;
    return $self->dbh->selectcol_arrayref(q{
        SELECT EXISTS(
            SELECT 1
              FROM all_tables
             WHERE owner = COALESCE(UPPER(?), SYS_CONTEXT('USERENV', 'SESSION_SCHEMA'))
               AND table_name = 'CHANGES'
        )
    }, undef, $self->sqitch_schema)->[0];
}

sub initialize {
    my $self   = shift;
    my $schema = $self->sqitch_schema;
    hurl engine => __x( 'Sqitch already initialized' ) if $self->initialized;

    # Load up our database.
    my $file = file(__FILE__)->dir->file('oracle.sql');


    $self->_run(
        (
            $schema ? (
                "DEFINE sqitch_schema=$schema"
            ) : (
                # Select the current schema into &sqitch_schema.
                # http://www.orafaq.com/node/515
                'COLUMN sname for a30 new_value sqitch_schema',
                q{SELECT SYS_CONTEXT('USERENV', 'SESSION_SCHEMA') AS sname FROM DUAL},
            )
        ),
        '@' . file(__FILE__)->dir->file('oracle.sql')
    );

    $self->dbh->do('ALTER SESSION SET CURRENT_SCHEMA = ?', undef, $schema)
        if $schema;
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
    $self->_run('@' . $file);
}

sub run_verify {
    my ($self, $file) = @_;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    return $self->$meth('@'. $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    my $target = $self->_script;
    open my $tfh, '<:utf8_strict', \$target;
    $self->sqitch->spool( [$tfh, $fh], $self->client );
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
    return qq{to_char($col AT TIME ZONE 'UTC', 'YYYY:MM:DD:HH24:MI:SS')};
}

sub _dt($) {
    require App::Sqitch::DateTime;
    my %params;
    @params{qw(time_zone year month day hour minute second)} = (
        'UTC',
        split /:/ => shift
    );
    return App::Sqitch::DateTime->new(%params);
}

sub _no_table_error  {
    return $DBI::err == 942; # ORA-00942: table or view does not exist
}

sub _script {
    my $self   = shift;
    my $target = $self->username // '';
    if (my $pass = $self->password) {
        $target .= "/$pass";
    }
    if (my $db = $self->db_name) {
        $target .= '@' if length $target;
        $target .= $db;
    }

    return join "\n" => (
        'SET ECHO OFF NEWP 0 SPA 0 PAGES 0 FEED OFF HEAD OFF TRIMS ON TAB OFF',
        'WHENEVER OSERROR EXIT 9;',
        'WHENEVER SQLERROR EXIT SQL.SQLCODE;',
        "connect $target",
        @_
    );
}

sub _run {
    my $self = shift;
    my $target = $self->_script(@_);
    open my $fh, '<:utf8_strict', \$target;
    return $self->sqitch->spool( $fh, $self->sqlplus );
}

sub _capture {
    my $self = shift;
    my $target = $self->_script(@_);
    my @out;

    require IPC::Run3;
    IPC::Run3::run3( [$self->sqlplus], \$target, \@out );
    hurl io => __x(
        '{command} unexpectedly returned exit value {exitval}',
        command => $_[0],
        exitval => ($? >> 8),
    ) if $?;

    return wantarray ? @out : \@out;
}

__PACKAGE__->meta->make_immutable;
no Mouse;

__END__

=head1 Name

App::Sqitch::Engine::oracle - Sqitch Oracle Engine

=head1 Synopsis

  my $oracle = App::Sqitch::Engine->load( engine => 'oracle' );

=head1 Description

App::Sqitch::Engine::oracle provides the Oracle storage engine for Sqitch. It
supports Oracle 8.4.0 and higher.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::oracle->config_vars;

Returns a hash of names and types to use for variables in the C<core.oracle>
section of the a Sqitch configuration file. The variables and their types are:

  client        => 'any'
  username      => 'any'
  password      => 'any'
  db_name       => 'any'
  host          => 'any'
  port          => 'int'
  sqitch_schema => 'any'

=head2 Instance Methods

=head3 C<initialized>

  $oracle->initialize unless $oracle->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $oracle->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema.

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
