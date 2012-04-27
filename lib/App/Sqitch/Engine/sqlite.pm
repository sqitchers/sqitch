package App::Sqitch::Engine::sqlite;

use v5.10.1;
use strict;
use warnings;
use utf8;
use namespace::autoclean;
use Moose;

extends 'App::Sqitch::Engine';

has client => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        $sqitch->client
            || $sqitch->config->get(key => 'core.sqlite.client')
            || 'sqlite3' . ($^O eq 'Win32' ? '.exe' : '');
    },
);

has db_file => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $sqitch = shift->sqitch;
        # Return the sqitch db_name if it is not the default.
        my $attr = $sqitch->meta->find_attribute_by_name('db_name');
        my $sqitch_client = $attr->get_value($sqitch);
        if ($sqitch_client ne $attr->default($sqitch)) {
            return $sqitch_client;
        }
        return $sqitch->config->get(key => 'core.sqlite.db_file');
    },
);

has sqitch_prefix => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    required => 1,
    default  => sub {
        shift->sqitch->config->get(key => 'core.sqlite.sqitch_prefix')
            || 'sqitch';
    },
);

sub config_vars {
    return (
        client        => 'any',
        db_file       => 'any',
        sqitch_prefix => 'any',
    );
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine::sqlite - Sqitch SQLite Engine

=head1 Synopsis

  my $sqlite = App::Sqitch::Engine->load( engine => 'sqlite' );

=head1 Description

App::Sqitch::Engine::sqlite provides the SQLite storage engine for Sqitch.

=head1 Interface

=head3 Class Methods

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine::sqlite->config_vars;

Returns a hash of names and types to use for variables in the C<core.sqlite>
section of the a Sqitch configuration file. The variables and their types are:

  client        => 'any'
  db_file       => 'any'
  sqitch_prefix => 'any'

=head2 Accessors

=head3 C<client>

Returns the path to the SQLite client. If C<--client> was passed to L<sqitch>,
that's what will be returned. Otherwise, it uses the C<core.sqlite.client>
configuration value, or else defaults to C<sqlite3> (or C<sqlite3.exe> on
Windows), which should work if it's in your path.

=head3 C<db_file>

Returns the name of the database file. If C<--db-name> was passed to L<sqitch>
that's what will be returned.

=head3 C<sqitch_prefix>

Returns the prefix to use for the Sqitch metadata tables. Returns the value of
the L<core.sqlite.sqitch_prefix> configuration value, or else defaults to
"sqitch".

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
