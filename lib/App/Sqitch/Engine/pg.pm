package App::Sqitch::Engine::pg;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Path::Class;
use namespace::autoclean;
use Moose;

extends 'App::Sqitch::Engine';

our $VERSION = '0.30';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->client
            || $sqitch->config->get( key => 'core.pg.client' )
            || 'psql' . ( $^O eq 'Win32' ? '.exe' : '' );
    },
);

has username => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->username || $sqitch->config->get( key => 'core.pg.username' );
    },
);

has password => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        shift->sqitch->config->get( key => 'core.pg.password' );
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
        $sqitch->db_name || $sqitch->config->get( key => 'core.pg.db_name' );
    },
);

has target => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self = shift;
        $self->db_name
            || $ENV{PGDATABASE}
            || $self->username
            || $ENV{PGUSER}
            || $ENV{USER};
    },
);

has host => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->host || $sqitch->config->get( key => 'core.pg.host' );
    },
);

has port => (
    is       => 'ro',
    isa      => 'Maybe[Int]',
    lazy     => 1,
    required => 0,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->port || $sqitch->config->get( key => 'core.pg.port' );
    },
);

has sqitch_schema => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get( key => 'core.pg.sqitch_schema' )
            || 'sqitch';
    },
);

has psql => (
    is         => 'ro',
    isa        => 'ArrayRef',
    lazy       => 1,
    required   => 1,
    auto_deref => 1,
    default    => sub {
        my $self = shift;
        my @ret  = ( $self->client );
        for my $spec (
            [ username => $self->username ],
            [ dbname   => $self->db_name  ],
            [ host     => $self->host     ],
            [ port     => $self->port     ],
            )
        {
            push @ret, "--$spec->[0]" => $spec->[1] if $spec->[1];
        }

        push @ret => (
            '--quiet',
            '--no-psqlrc',
            '--no-align',
            '--tuples-only',
            '--set' => 'ON_ERROR_ROLLBACK=1',
            '--set' => 'ON_ERROR_STOP=1',
        );
        return \@ret;
    },
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

sub initialized {
    my $self = shift;
    ( my $ns = $self->sqitch_schema ) =~ s/'/''/g;
    return $self->_probe( '--command' => qq{
        SELECT EXISTS(
            SELECT TRUE FROM pg_catalog.pg_namespace WHERE nspname = '$ns'
        )::int
    });
}

sub initialize {
    my $self = shift;
    $self->sqitch->bail(
        1, 'Sqitch schema "', $self->sqitch_schema, '" already exists'
    ) if $self->initialized;

    my $file = file(__FILE__)->dir->file('pg.sql');
    return $self->_run(
        '--file' => $file,
        '--set'  => 'sqitch_schema=' . $self->sqitch_schema
    );
}

sub run_file {
    my ($self, $file) = @_;
    $self->_run('--file' => $file);
}

sub run_handle {
    my ($self, $fh) = @_;
    $self->_spool($fh);
}

sub _array {
    return '{'
        . join(',' => map { s/(["\\])/\\$1/g; /[,{}]/ ? qq{"$_"} : $_ } @_)
        . '}';
}

sub _log_step {
    my ( $self, $step, $query ) = @_;
    my $sqitch = $self->sqitch;
    $self->_run(
        '--single-transaction',
        '--set'     => 'ON_ERROR_ROLLBACK=1',
        '--set'     => 'ON_ERROR_STOP=1',
        '--set'     => 'sqitch_schema=' . $self->sqitch_schema,
        '--set'     => 'step='          . $step->name,
        '--set'     => 'tags='          . _array($step->tag->names),
        '--set'     => 'requires='      . _array($step->requires),
        '--set'     => 'conflicts='     . _array($step->conflicts),
        '--command' => $query,
    );
}

sub log_revert_step {
    my ($self, $step) = @_;
    $self->_log_step($step, q{
        DELETE FROM :"sqitch_schema".steps where step = :'step' AND tags = :'tags';
        INSERT INTO :"sqitch_schema".history (action, step, tags, requires, conflicts)
        VALUES ('revert', :'step', :'tags', :'requires', :'conflicts');
    });
}

sub log_deploy_step {
    my ($self, $step) = @_;
    $self->_log_step($step, q{
        INSERT INTO :"sqitch_schema".steps (step, tags, requires, conflicts)
        VALUES (:'step', :'tags', :'requires', :'conflicts');
        INSERT INTO :"sqitch_schema".history (action, step, tags, requires, conflicts)
        VALUES ('deploy', :'step', :'tags', :'requires', :'conflicts');
    });
}

sub _log_tag {
    my ( $self, $tag, $query ) = @_;
    my $sqitch = $self->sqitch;
    $self->_run(
        '--single-transaction',
        '--set'     => 'ON_ERROR_ROLLBACK=1',
        '--set'     => 'ON_ERROR_STOP=1',
        '--set'     => 'sqitch_schema=' . $self->sqitch_schema,
        '--set'     => 'tags='          . _array($tag->names),
        '--set'     => 'steps='         . _array(map { $_->name } $tag->steps),
        '--command' => $query,
    );
}

sub log_deploy_tag {
    my ( $self, $tag ) = @_;
    $self->_log_tag($tag, q{
        INSERT INTO :"sqitch_schema".tags (tag, steps)
        SELECT t FROM UNNEST(:'tags') AS t;
    });
}

sub is_deployed_tag {
    my ( $self, $tag ) = @_;
    return $self->_probe(
        '--set'     => 'tags=' . _array($tag->names),
        # XXX Not an ideal way to deal with multi-name tags.
        '--command' => q{
            SELECT EXISTS(
                SELECT TRUE
                  FROM :"sqitch_schema".tags
                 WHERE tag = ANY(:'tags');
            )
        },
    );
}

sub is_deployed_step {
    my ( $self, $step ) = @_;
    return $self->_probe(
        '--set'     => 'step=' . $step->name,
        '--set'     => 'tags=' . _array($step->tag->names),
        '--command' => q{
            SELECT EXISTS(
                SELECT TRUE
                  FROM :"sqitch_schema".steps
                 WHERE step = :'step'
                   AND tags = ANY(:'tags');
            )
        },
    );
}

sub log_revert_tag {
    my ( $self, $tag ) = @_;
    $self->_log_tag(
        $tag,
        q{DELETE FROM :"sqitch_schema".tags WHERE tag = ANY(:'tags');},
    );
}

sub deployed_steps_for {
    my ( $self, $tag ) = @_;
    # XXX Need to sort by dependency order.
    return map {
        chomp;
        App::Sqitch::Plan::Step->new(name => $_, tag => $tag)
    } $self->_cap(
        '--set'     => 'tags=' . _array($tag->names),
        '--command' => q{
            SELECT step
              FROM :"sqitch_schema".steps
             WHERE tags = :'tags'
             ORDER BY deployed_at
        },
    );
}

sub _run {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->run( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->run( $self->psql, @_ );
}

sub _cap {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->capture( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->capture( $self->psql, @_ );
}

sub _probe {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->probe( $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->probe( $self->psql, @_ );
}

sub _spool {
    my $self   = shift;
    my $fh     = shift;
    my $sqitch = $self->sqitch;
    my $pass   = $self->password or return $sqitch->spool( $fh, $self->psql, @_ );
    local $ENV{PGPASSWORD} = $pass;
    return $sqitch->spool( $fh, $self->psql, @_ );
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine::pg - Sqitch PostgreSQL Engine

=head1 Synopsis

  my $pg = App::Sqitch::Engine->load( engine => 'pg' );

=head1 Description

App::Sqitch::Engine::pg provides the PostgreSQL storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::pg->config_vars;

Returns a hash of names and types to use for variables in the C<core.pg>
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

  $pg->initialize unless $pg->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $pg->initialize;

Initializes a database for Sqitch by installing the Sqitch metadata schema.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012 iovation Inc.

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
