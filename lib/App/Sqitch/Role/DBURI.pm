package App::Sqitch::Role::DBURI;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse::Role;
use URI::db;
use namespace::autoclean;

requires 'sqitch';

our $VERSION = '0.984';

has db_uri => ( is => 'ro', isa => 'URI::db', lazy => 1, default => sub {
    my $self = shift;
    my $engine = $self->sqitch->_engine;
    return $self->_merge( URI::db->new("db:$engine:") );
});

sub BUILD {
    my ($self, $args) = @_;
    my $uri = $args->{db_uri} or return;
    $self->_merge($uri);
}

sub _merge {
    my ($self, $uri) = @_;
    my $sqitch = $self->sqitch;

    if (my $host = $sqitch->db_host) {
        $uri->host($host);
    }

    if (my $port = $sqitch->db_port) {
        $uri->port($port);
    }

    if (my $user = $sqitch->db_username) {
        $uri->user($user);
    }

    if (my $name = $sqitch->db_name) {
        $uri->dbname($name);
    }

    return $uri;
}

1;

__END__

=head1 Name

App::Sqitch::Role::DBURI - A class that has a db_uri attribute

=head1 Synopsis

  package App::Sqitch::Whatever;
  use Mouse;
  with 'App::Sqitch::Role::DBURI';
  has sqitch => ( is => 'ro', isa => 'App::Sqitch', required => 1 );

=head1 Description

This role defines a C<db_uri> attribute, which contains a L<URI::db> object.
On assignment, any values passed to the L<App::Sqitch> C<db_*> methods are
merged into the URI.

=head1 Interface

=head2 Attaributes

=head3 C<db_uri>

  my $db_uri = $obj->db_uri;

Returns a database URI. If none has been passed to the constructor, the URI
will consist of parts passed via the C<db_*> attributes of the required
App::Sqitch object. If one was passed to the constructor, those values will be
merged into the URI.

=head1 See Also

=over

=item L<App::Sqitch::Engine>

The Sqitch database engine base class.

=back

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
