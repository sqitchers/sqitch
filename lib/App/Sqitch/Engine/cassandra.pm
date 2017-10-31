package App::Sqitch::Engine::cassandra;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use DBI;
use Try::Tiny;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::Plan::Change;
use List::Util qw(first);
use App::Sqitch::Types qw(DBH ArrayRef);
use namespace::autoclean;

extends 'App::Sqitch::Engine';

our $VERSION = '0.9997';

has _cqsql => (
	is      => 'ro',
	isa     => ArrayRef,
	lazy    => 1,
	default => sub {
		my $self = shift;
		my $uri = $self->uri;
		my @ret = ($self->client);
		for my $spec (
			[ username => $self->username ],
			[ keyspace => $self->dbname ],
		)
		{
			push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
		}

		push @ret => $self->_client_opts;

		return \@ret;
	},
);

sub _client_ops {
	my $self = shift;
	return (
		'--ssql',
		'--no-color',
	);
}

sub cqsql {
	@{ shift->_cqsql }
}

sub key    { 'cassandra' }
sub name   { 'Cassandra' }
sub driver { 'DBD::Cassandra 0.56' }
sub default_client { 'cqlsh' }

sub destination {
	my $self = shift;
	return $self->target->name if $self->target->name !~ /:/
		|| $self->target->uri->dbname;
}

has dbh => (
	is => 'rw',
	isa => DBH,
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->use_driver;

		my $uri = $self->uri;
		DBI->connect($uri->dbi_dsn, scalar $self->username, scalar $self->password, {
			PrintError  => 0,
			RaiseError  => 0,
			AutoCommit  => 1,
			HandleError => sub {
				my ($err, $dbh) = @_;
				$@ = $err;
				@_ = ($dbh->state || 'DEV' => $dbh->errstr);
				goto &hurl;
			},
			Callbacks   => {
				connected => sub {
					my $dbh = shift;
					$dbh->set_err(undef, undef) if $dbh->err;
					return;
				},
			},
		});
	}
);

with 'App::Sqitch::Role::DBIEngine';

sub _ts_default {
	q{toTimestamp(now())}
}

sub _ts2char_format {
	my $self = shift;
	my $schema = $self->registry;
	"{schema}.dt_format(%s)";
}

sub _char2ts {
	$_[1]->as_string(format => 'iso')
}

sub _listagg_format {
	q{%s}
}

sub _no_table_error  {
	0;
}

sub _regex_op { '=' }

sub initialized {
	my $self = shift;
	return $self->dbh->selectcol_arrayref(q{
		SELECT COUNT(*) FROM system_schema.keyspaces
		 WHERE keyspace_name = ?
	}, undef, $self->registry)->[0];
}

sub initialize {
	my $self = shift;
	my $schema = $self->registry;
	hurl engine => __x(
		'Sqitch schema "{schema}" already exists',
		schema => $schema
	) if $self->initialized;

	$self->_run_registry_file(file(__FILE__)->dir->file('cassandra.cql'));
	$self->_register_release;
}

sub run_file {
	my ($self, $file) = @_;
	$self->_run('--file' => $file);
}

sub run_verify {
	my $self = shift;
	my $meth = $self->can($self->sqitch->verbosity > 1? '_run' : '_capture');
	$self->$meth(@_);
}

sub run_handle {
	my ($self, $fh) = @_;
	$self->_spool($fh);
}

sub run_upgrade {
	shift->_run_registry_file(@_);
}

sub _run_registry_file {
	my ($self, $file) = @_;
	my $schema = $self->registry;

	my $vline = $self->_probe('-e', 'SHOW VERSION');
	my ($maj) = $vline =~ / Cassandra (\d+)\./;
	# TODO how to use the $maj?

	(my $sql = scalar $file->slurp) =~ s{:"registry"}{$schema}g;

	require File::Temp;
	my $fh = File::Temp->new;
	print $fh $sql;
	close $fh;

	$self->_run('--file' => $fh->filename);
}

sub _run {
	my $self = shift;
	my $sqitch = $self->sqitch;

	my @args = ($self->client);
	push @args => @_;
	push @args => $self->host;
	push @args => $self->_port;

	return $sqitch->run($self->cqlsh, @args);
}

sub _probe {
	my $self = shift;
	my $sqitch = $self->sqitch;

	my @args = ($self->client);
	push @args => @_;
	push @args => $self->host;
	push @args => $self->_port;

	return $sqitch->probe($self->cqlsh, @args);
}

sub _spool {
	my $self = shift;
	my $fh = shift;
	my $sqitch = $self->sqitch;

	my @args = ($self->client);
	push @args => @_;
	push @args => $self->host;
	push @args => $self->_port;

	return $sqitch->spool($fh, $self->cqlsh, @args);
}

sub _capture {
	my $self = shift;
	my $fh = shift;
	my $sqitch = $self->sqitch;

	my @args = ($self->client);
	push @args => @_;
	push @args => $self->host;
	push @args => $self->_port;

	return $sqitch->spool($self->cqlsh, @args);
}

sub begin_work {
	my $self = shift;
	my $dbh = $self->dbh;

	$dbh->do('CONSISTENCY ALL');
	$dbh->begin_work;
	return $self;
}

sub finish_work {
	my $self = shift;
	return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Engine::cassandra - Sqitch Cassandra Engine

=head1 Synopsis

  my $cassandra = App::Sqitch::Engine->load( engine => 'cassandra' );

=head1 Description

App::Sqitch::Engine::cassandra provides the Cassandra storage engine for Sqitch.
It support Cassandra 3.

=head1 Interface

=head3 C<initialized>

  $cassandra->initialize unless $cassandra->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $cassandra->initialize;

Initializes a database for Sqitch by installing the Sqitch registry schema.

=head1 Author

Jan Viktorin <iviktorin@fit.vutbr.cz>

=head1 License

Copyright (c) 2017 Jan Viktorin

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

=cur
