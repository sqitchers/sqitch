package App::Sqitch::Engine::cockroach;

use 5.010;
use Moo;
use namespace::autoclean;

extends 'App::Sqitch::Engine::pg';

# VERSION

sub key    { 'cockroach' }
sub name   { 'CockroachDB' }
sub driver { 'DBD::Pg 2.0' }

sub _ts2char_format {
    q{experimental_strftime(%s AT TIME ZONE 'UTC', 'year:%%Y:month:%%m:day:%%d:hour:%%H:minute:%%M:second:%%S:time_zone:UTC')};
}

# Override to avoid locking the changes table, as Cockroach does not support
# explicit table locks.
sub begin_work {
    my $self = shift;
    $self->dbh->begin_work;
    return $self;
}

# Override to return true, as Cockroach does not support advisory locks.
sub wait_lock {
    # Cockroach does not support advisory locks.
    # https://github.com/cockroachdb/cockroach/issues/13546
    return 1;
}

sub _no_table_error  {
    $DBI::state && $DBI::state eq '42P01'; # undefined_table
}

sub _run_registry_file {
    my ($self, $file) = @_;
    my $schema = $self->registry;

    $self->_run(
        '--file' => $file,
        '--set'  => "registry=$schema",
    );

    $self->dbh->do('SET search_path = ?', undef, $schema);
}

1;

__END__

=head1 Name

App::Sqitch::Engine::cockroach - Sqitch CockroachDB Engine

=head1 Synopsis

  my $pg = App::Sqitch::Engine->load( engine => 'cockroach' );

=head1 Description

App::Sqitch::Engine::cockroach provides the CockroachDB storage engine for Sqitch. It
supports CockroachDB v21 and higher, and relies on the Postgres toolchain (C<psql>
client, L<DBD::Pg> database driver, etc.).

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2021 iovation Inc., David E. Wheeler

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
