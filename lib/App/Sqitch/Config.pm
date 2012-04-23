package App::Sqitch::Config;

use v5.10;
use Moose;
use strict;
use warnings;
use Config;
use Path::Class;
use Carp;
use utf8;

extends 'Config::GitLike';

our $VERSION = '0.10';

has '+confname' => (
    default => 'sqitch.conf',
);

sub system_file {
    return $ENV{SQITCH_SYSTEM_CONFIG} || file(
        $Config{prefix}, 'etc', shift->confname
    );
}

sub global_file { shift->system_file }

sub user_file {
    return $ENV{SQITCH_USER_CONFIG} if $ENV{SQITCH_USER_CONFIG};

    require File::HomeDir;
    my $hd = File::HomeDir->my_home or croak(
        "Could not determine home directory"
    );
    return file $hd, '.sqitch', shift->confname;
}

sub dir_file {
    return file +File::Spec->curdir, shift->confname;
}

sub get_section {
    my ($self, %p) = @_;
    $self->load unless $self->is_loaded;
    my $section = $p{section} // '';
    my $data    = $self->data;
    return {
        map  { $_ => $data->{"$section.$_"} }
        grep { s{^\Q$section.\E([^.]+)$}{$1} } keys %{ $data }
    };
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;

=head1 Name

App::Sqitch::Config - Sqitch configuration management

=head1 Synopsis

  my $config = App::Sqitch::Config->new;
  say scalar $config->dump;

=head1 Description

This class provides the interface to Sqitch configuration. It inherits from
L<Config::GitLike>, and therefore provides the complete interface of that
module.

=head1 Interface

=head2 Instance Methods

=head3 C<confname>

Returns the configuration file base name, which is F<sqitch.conf>.

=head3 C<system_file>

Returns the path to the system configuration file. The value returned will be
the contents of the C<$SQITCH_SYSTEM_CONFIG> environment variable, if it's
defined, or else C<$Config{prefix}/etc/sqitch.conf>.

=head3 C<global_file>

An alias for C<system_file()> for use by the parent class.

=head3 C<user_file>

Returns the path to the user configuration file. The value returned will be
the contents of the C<$SQITCH_USER_CONFIG> environment variable, if it's
defined, or else C<~/.sqitch/sqitch.conf>.

=head3 C<dir_file>

Returns the path to the project configuration file, which is just
F<./sqitch.conf>.

=head3 C<get_section>

  my $core = $config->get_section(section => 'core');
  my $pg   = $config->get_section(section => 'core.pg');

Returns a hash reference containing only the keys within the specified
section or subsection.

=head1 See Also

=over

=item * L<Config::GitLike>

=item * L<App::Sqitch::Command::config>

=item * L<sqitch-config>

=back

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

