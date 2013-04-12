package App::Sqitch::Config;

use 5.010;
use Moose;
use strict;
use warnings;
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Config::GitLike 1.09;
use utf8;

extends 'Config::GitLike';

our $VERSION = '0.964';

has '+confname' => ( default => 'sqitch.conf' );
has '+encoding' => ( default => 'UTF-8' );

# Set by ./Build; see Module::Build::Sqitch for details.
my $SYSTEM_DIR = undef;

sub user_dir {
    require File::HomeDir;
    my $hd = File::HomeDir->my_home or hurl config => __(
        "Could not determine home directory"
    );
    return dir $hd, '.sqitch';
}

sub system_dir {
    dir $SYSTEM_DIR || do {
        require Config;
        $Config::Config{prefix}, 'etc', 'sqitch';
    };
}

sub system_file {
    my $self = shift;
    return file $ENV{SQITCH_SYSTEM_CONFIG}
        || $self->system_dir->file( $self->confname );
}

sub global_file { shift->system_file }

sub user_file {
    my $self = shift;
    return file $ENV{SQITCH_USER_CONFIG}
        || $self->user_dir->file( $self->confname );
}

sub local_file {
    return file $ENV{SQITCH_CONFIG} if $ENV{SQITCH_CONFIG};
    return file shift->confname;
}

sub dir_file { shift->local_file }

sub get_section {
    my ( $self, %p ) = @_;
    $self->load unless $self->is_loaded;
    my $section = lc $p{section} // '';
    my $data    = $self->data;
    return {
        map  {
            ( split /[.]/ => $self->initial_key("$section.$_") )[-1],
            $data->{"$section.$_"}
        }
        grep { s{^\Q$section.\E([^.]+)$}{$1} } keys %{$data}
    };
}

# Mock up original_key for older versions fo Config::GitLike.
eval 'sub original_key { $_[1] }' unless __PACKAGE__->can('original_key');

sub initial_key {
    my $key = shift->original_key(shift);
    return ref $key ? $key->[0] : $key;
}

__PACKAGE__->meta->make_immutable;
no Mouse;

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

=head3 C<system_dir>

Returns the path to the system configuration directory, which is
C<$Config{prefix}/etc/sqitch/>.

=head3 C<user_dir>

Returns the path to the user configuration directory, which is F<~/.sqitch/>.

=head3 C<system_file>

Returns the path to the system configuration file. The value returned will be
the contents of the C<$SQITCH_SYSTEM_CONFIG> environment variable, if it's
defined, or else C<$Config{prefix}/etc/sqitch/sqitch.conf>.

=head3 C<global_file>

An alias for C<system_file()> for use by the parent class.

=head3 C<user_file>

Returns the path to the user configuration file. The value returned will be
the contents of the C<$SQITCH_USER_CONFIG> environment variable, if it's
defined, or else C<~/.sqitch/sqitch.conf>.

=head3 C<local_file>

Returns the path to the local configuration file, which is just
F<./sqitch.conf>, unless C<$SQITCH_CONFIG> is set, in which case its value
will be returned.

=head3 C<dir_file>

An alias for C<local_file()> for use by the parent class.

=head3 C<get_section>

  my $core = $config->get_section(section => 'core');
  my $pg   = $config->get_section(section => 'core.pg');

Returns a hash reference containing only the keys within the specified
section or subsection.

=head3 C<add_comment>

Adds a comment to the configuration file.

=head3 C<initial_key>

  my $key = $config->initial_key($data_key);

Given the lowercase key from the loaded data, this method returns it in its
original case. This is like C<original_key>, only in the case where there are
multiple keys (for multivalue keys), only the first key is returned.

=begin comment

Hide <original_key>: It is defined in Config::GitLike 1.10, and only defined
here for older versions.

=head3 C<original_key>

Only provided if not inherited from Config::GitLike.

=end comment

=head1 See Also

=over

=item * L<Config::GitLike>

=item * L<App::Sqitch::Command::config>

=item * L<sqitch-config>

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

