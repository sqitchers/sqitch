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
use Moo;
use App::Sqitch::Types qw(DBH URIDB ArrayRef Bool Str HashRef);
use namespace::autoclean;
use List::MoreUtils qw(firstidx);

extends 'App::Sqitch::Engine';

# VERSION

has uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri = $self->SUPER::uri;
        $uri->host($ENV{MYSQL_HOST})     if !$uri->host  && $ENV{MYSQL_HOST};
        $uri->port($ENV{MYSQL_TCP_PORT}) if !$uri->_port && $ENV{MYSQL_TCP_PORT};
        return $uri;
    },
);

has registry_uri => (
    is       => 'ro',
    isa      => URIDB,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $uri = $self->uri->clone;
        $uri->dbname($self->registry);
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

has _mycnf => (
    is => 'rw',
    isa     => HashRef,
    default => sub {
        eval 'require MySQL::Config; 1' or return {};
        return scalar MySQL::Config::parse_defaults('my', [qw(client mysql)]);
    },
);

sub _def_user { $_[0]->_mycnf->{user} || $_[0]->sqitch->sysuser }
sub _def_pass { $ENV{MYSQL_PWD} || shift->_mycnf->{password} }

has dbh => (
    is      => 'rw',
    isa     => DBH,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->use_driver;
        my $uri = $self->registry_uri;
        my $dbh = DBI->connect($uri->dbi_dsn, $self->username, $self->password, {
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
                    $dbh->do("SET SESSION $_") or return for (
                        q{character_set_client   = 'utf8'},
                        q{character_set_server   = 'utf8'},
                        ($dbh->{mysql_serverversion} || 0 < 50500 ? () : (q{default_storage_engine = 'InnoDB'})),
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
        });

        # Make sure we support this version.
        my ($dbms, $vnum, $vstr) = $dbh->{mysql_serverinfo} =~ /mariadb/i
            ? ('MariaDB', 50300, '5.3')
            : ('MySQL',   50100, '5.1.0');
        hurl mysql => __x(
            'Sqitch requires {rdbms} {want_version} or higher; this is {have_version}',
            rdbms        => $dbms,
            want_version => $vstr,
            have_version => $dbh->selectcol_arrayref('SELECT version()')->[0],
        ) unless $dbh->{mysql_serverversion} >= $vnum;

        return $dbh;
    }
);

has _ts_default => (
    is      => 'ro',
    isa     => Str,
    lazy    => 1,
    default => sub {
        return 'utc_timestamp(6)' if shift->_fractional_seconds;
        return 'utc_timestamp';
    },
);

# Need to wait until dbh and _ts_default are defined.
with 'App::Sqitch::Role::DBIEngine';

has _mysql => (
    is         => 'ro',
    isa        => ArrayRef,
    lazy       => 1,
    default    => sub {
        my $self = shift;
        my $uri  = $self->uri;

        $self->sqitch->warn(__x
            'Database name missing in URI "{uri}"',
            uri => $uri
        ) unless $uri->dbname;

        my @ret  = ( $self->client );
        # Use _port instead of port so it's empty if no port is in the URI.
        # https://github.com/sqitchers/sqitch/issues/675
        for my $spec (
            [ user     => $self->username ],
            [ database => $uri->dbname    ],
            [ host     => $uri->host      ],
            [ port     => $uri->_port     ],
        ) {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        # Special-case --password, which requires = before the value. O_o
        if (my $pw = $self->password) {
            my $cfgpwd = $self->_mycnf->{password} || '';
            push @ret, "--password=$pw" if $pw ne $cfgpwd;
        }

        # Options to keep things quiet.
        push @ret => (
            (App::Sqitch::ISWIN ? () : '--skip-pager' ),
            '--silent',
            '--skip-column-names',
            '--skip-line-numbers',
        );

        # Get Maria to abort properly on error.
        my $vinfo = try { $self->sqitch->probe($self->client, '--version') } || '';
        if ($vinfo =~ /mariadb/i) {
            my ($version) = $vinfo =~ /(?:Ver|client)\s+(\S+)/;
            my ($maj, undef, $pat) = split /[.]/ => $version;
            push @ret => '--abort-source-on-error'
                if $maj > 5 || ($maj == 5 && $pat >= 66);
        }

        # Add relevant query args.
        if (my @p = $uri->query_params) {
            my %option_for = (
                mysql_compression     => sub { $_[0] ? '--compress' : ()  },
                mysql_ssl             => sub { $_[0] ? '--ssl'      : ()  },
                mysql_connect_timeout => sub { '--connect_timeout', $_[0] },
                mysql_init_command    => sub { '--init-command',    $_[0] },
                mysql_socket          => sub { '--socket',          $_[0] },
                mysql_ssl_client_key  => sub { '--ssl-key',         $_[0] },
                mysql_ssl_client_cert => sub { '--ssl-cert',        $_[0] },
                mysql_ssl_ca_file     => sub { '--ssl-ca',          $_[0] },
                mysql_ssl_ca_path     => sub { '--ssl-capath',      $_[0] },
                mysql_ssl_cipher      => sub { '--ssl-cipher',      $_[0] },
            );
            while (@p) {
                my ($k, $v) = (shift @p, shift @p);
                my $code = $option_for{$k} or next;
                push @ret => $code->($v);
            }
        }

        return \@ret;
    },
);

has _fractional_seconds => (
    is      => 'ro',
    isa     => Bool,
    lazy    => 1,
    default => sub {
        my $dbh = shift->dbh;
        return $dbh->{mysql_serverinfo} =~ /mariadb/i
            ? $dbh->{mysql_serverversion} >= 50305
            : $dbh->{mysql_serverversion} >= 50604;
    },
);

sub mysql { @{ shift->_mysql } }

sub key    { 'mysql' }
sub name   { 'MySQL' }
sub driver { 'DBD::mysql 4.018' }
sub default_client { 'mysql' }

sub _char2ts {
    $_[1]->set_time_zone('UTC')->iso8601;
}

sub _ts2char_format {
    return q{date_format(%s, 'year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%i:second:%%S:time_zone:UTC')};
}

sub _quote_idents {
    shift;
    map { $_ eq 'change' ? '"change"' : $_ } @_;
}

sub _version_query { 'SELECT CAST(ROUND(MAX(version), 1) AS CHAR) FROM releases' }

has initialized => (
    is      => 'ro',
    isa     => Bool,
    lazy    => 1,
    writer  => '_set_initialized',
    default => sub {
        my $self = shift;

        # Try to connect.
        my $dbh = try { $self->dbh } catch {
            # MySQL error code 1049 (ER_BAD_DB_ERROR): Unknown database '%-.192s'
            return if $DBI::err && $DBI::err == 1049;
            die $_;
        } or return 0;

        return $dbh->selectcol_arrayref(q{
            SELECT COUNT(*)
            FROM information_schema.tables
            WHERE table_schema = ?
            AND table_name   = ?
        }, undef, $self->registry, 'changes')->[0];
    }
);

sub _initialize {
    my $self   = shift;
    hurl engine => __x(
        'Sqitch database {database} already initialized',
        database => $self->registry,
    ) if $self->initialized;

    # Create the Sqitch database if it does not exist.
    (my $db = $self->registry) =~ s/"/""/g;
    $self->_run(
        '--execute'  => sprintf(
            'SET sql_mode = ansi; CREATE DATABASE IF NOT EXISTS "%s"',
            $self->registry
        ),
    );

    # Deploy the registry to the Sqitch database.
    $self->run_upgrade( file(__FILE__)->dir->file('mysql.sql') );
    $self->_set_initialized(1);
    $self->_register_release;
}

# Override to lock the Sqitch tables. This ensures that only one instance of
# Sqitch runs at one time.
sub begin_work {
    my $self = shift;
    my $dbh = $self->dbh;

    # Start transaction and lock all tables to disallow concurrent changes.
    $dbh->do('LOCK TABLES ' . join ', ', map {
        "$_ WRITE"
    } qw(releases changes dependencies events projects tags));
    $dbh->begin_work;
    return $self;
}

# We include the database name in the lock name because that's probably the most
# stringent lock the user expects. Locking the whole server with a static string
# prevents parallel deploys to other databases. Yes, locking just the target
# allows parallel deploys to conflict with one another if they make changes to
# other databases, but is not a great practice and likely an anti-pattern. So
# stick with the least surprising behavior.
# https://github.com/sqitchers/sqitch/issues/670
sub _lock_name {
    'sqitch working on ' . shift->uri->dbname
}

# Override to try to acquire a lock on the string "sqitch working on $dbname"
# without waiting.
sub try_lock {
    my $self = shift;
    # Can't create a lock in the registry if it doesn't exist.
    $self->initialize unless $self->initialized;
    $self->dbh->selectcol_arrayref(
        q{SELECT get_lock(?, ?)}, undef, $self->_lock_name, 0,
    )->[0]
}

# Override to try to acquire a lock on the string "sqitch working on $dbname",
# waiting for the lock until timeout.
sub wait_lock {
    my $self = shift;
    $self->dbh->selectcol_arrayref(
        q{SELECT get_lock(?, ?)}, undef,
        $self->_lock_name, $self->lock_timeout,
    )->[0]
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
    return $DBI::state && (
        $DBI::state eq '42S02' # ER_BAD_TABLE_ERROR
     ||
        ($DBI::state eq '42000' && $DBI::err == '1049') # ER_BAD_DB_ERROR
    )
}

sub _no_column_error  {
    return $DBI::state && $DBI::state eq '42S22' && $DBI::err == '1054'; # ER_BAD_FIELD_ERROR
}

sub _unique_error  {
    return $DBI::state && $DBI::state eq '23000' && $DBI::err == '1062'; # ER_DUP_ENTRY
}

sub _regex_op { 'REGEXP' }

sub _limit_default { '18446744073709551615' }

sub _listagg_format {
    return q{GROUP_CONCAT(%1$s ORDER BY %1$s SEPARATOR ' ')};
}

sub _prepare_to_log {
    my ($self, $table, $change) = @_;
    return $self if $self->_fractional_seconds;

    # No sub-second precision, so delay logging a change until a second has passed.
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare(qq{
        SELECT UNIX_TIMESTAMP(committed_at) >= UNIX_TIMESTAMP()
          FROM $table
         WHERE project = ?
         ORDER BY committed_at DESC
         LIMIT 1
    });
    while ($dbh->selectcol_arrayref($sth, undef, $change->project)->[0]) {
        # Sleep for 100 ms.
        require Time::HiRes;
        Time::HiRes::sleep(0.1);
    }

    return $self;
}

sub _set_vars {
    my %vars = shift->variables or return;
    return 'SET ' . join(', ', map {
        (my $k = $_) =~ s/"/""/g;
        (my $v = $vars{$_}) =~ s/'/''/g;
        qq{\@"$k" = '$v'};
    } sort keys %vars) . ";\n";
}

sub _source {
    my ($self, $file) = @_;
    my $set = $self->_set_vars || '';
    return ('--execute' => "${set}source $file");
}

sub _run {
    my $self = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->mysql, @_ );
    local $ENV{MYSQL_PWD} = $pass;
    return $sqitch->run( $self->mysql, @_ );
}

sub _capture {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->mysql, @_ );
    local $ENV{MYSQL_PWD} = $pass;
    return $sqitch->capture( $self->mysql, @_ );
}

sub _spool {
    my $self   = shift;
    my @fh     = (shift);
    my $sqitch = $self->sqitch;
    if (my $set = $self->_set_vars) {
        open my $sfh, '<:utf8_strict', \$set;
        unshift @fh, $sfh;
    }
    my $pass   = $self->password or return $sqitch->spool( \@fh, $self->mysql, @_ );
    local $ENV{MYSQL_PWD} = $pass;
    return $sqitch->spool( \@fh, $self->mysql, @_ );
}

sub run_file {
    my $self = shift;
    $self->_run( $self->_source(@_) );
}

sub run_verify {
    my $self = shift;
    # Suppress STDOUT unless we want extra verbosity.
    my $meth = $self->can($self->sqitch->verbosity > 1 ? '_run' : '_capture');
    $self->$meth( $self->_source(@_) );
}

sub run_upgrade {
    my ($self, $file) = @_;
    my @cmd = $self->mysql;
    $cmd[1 + firstidx { $_ eq '--database' } @cmd ] = $self->registry;
    return $self->sqitch->run( @cmd, $self->_source($file) )
        if $self->_fractional_seconds;

    # Need to strip out datetime precision.
    (my $sql = scalar $file->slurp) =~ s{DATETIME\(\d+\)}{DATETIME}g;

    # Strip out 5.5 stuff on earlier versions.
    $sql =~ s/-- ## BEGIN 5[.]5.+?-- ## END 5[.]5//ms
        if $self->dbh->{mysql_serverversion} < 50500;

    # Write out a temp file and execute it.
    require File::Temp;
    my $fh = File::Temp->new;
    print $fh $sql;
    close $fh;
    $self->sqitch->run( @cmd, $self->_source($fh) );
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

1;

1;

__END__

=head1 Name

App::Sqitch::Engine::mysql - Sqitch MySQL Engine

=head1 Synopsis

  my $mysql = App::Sqitch::Engine->load( engine => 'mysql' );

=head1 Description

App::Sqitch::Engine::mysql provides the MySQL storage engine for Sqitch. It
supports MySQL 5.1.0 and higher (best on 5.6.4 and higher), as well as MariaDB
5.3.0 and higher.

=head1 Interface

=head2 Instance Methods

=head3 C<mysql>

Returns a list containing the C<mysql> client and options to be passed to it.
Used internally when executing scripts. Query parameters in the URI that map
to C<mysql> client options will be passed to the client, as follows:

=over

=item * C<mysql_compression=1>: C<--compress>

=item * C<mysql_ssl=1>: C<--ssl>

=item * C<mysql_connect_timeout>: C<--connect_timeout>

=item * C<mysql_init_command>: C<--init-command>

=item * C<mysql_socket>: C<--socket>

=item * C<mysql_ssl_client_key>: C<--ssl-key>

=item * C<mysql_ssl_client_cert>: C<--ssl-cert>

=item * C<mysql_ssl_ca_file>: C<--ssl-ca>

=item * C<mysql_ssl_ca_path>: C<--ssl-capath>

=item * C<mysql_ssl_cipher>: C<--ssl-cipher>

=back

=head3 C<username>

=head3 C<password>

Overrides the methods provided by the target so that, if the target has
no username or password, Sqitch looks them up in the
L<F</etc/my.cnf> and F<~/.my.cnf> files|https://dev.mysql.com/doc/refman/5.7/en/password-security-user.html>.
These files must limit access only to the current user (C<0600>). Sqitch will
look for a username and password under the C<[client]> and C<[mysql]>
sections, in that order.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2023 iovation Inc., David E. Wheeler

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
