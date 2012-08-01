package App::Sqitch::Config;

use v5.10.1;
use Moose;
use strict;
use warnings;
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use utf8;

extends 'Config::GitLike';

our $VERSION = '0.80';

has '+confname' => ( default => 'sqitch.conf' );

# https://github.com/bestpractical/config-gitlike/pull/6
has '+encoding' => ( default => 'UTF-8' )
    if __PACKAGE__->meta->find_attribute_by_name('encoding');

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
    my $section = $p{section} // '';
    my $data    = $self->data;
    return {
        map { $_ => $data->{"$section.$_"} }
        grep { s{^\Q$section.\E([^.]+)$}{$1} } keys %{$data}
    };
}

# Remove once https://github.com/bestpractical/config-gitlike/pull/4 is merged
# and released.
sub add_comment {
    my $self = shift;
    my (%args) = (
        comment   => undef,
        filename  => undef,
        indented  => undef,
        semicolon => undef,
        @_
    );

    my $filename = $args{filename} or die "No filename passed to add_comment()";
    die "No comment to add\n" unless defined $args{comment};

    # Comment, preserving leading whitespace.
    my $chars = $args{indented}  ? '[[:blank:]]*' : '';
    my $char  = $args{semicolon} ? ';'            : '#';
    ( my $comment = $args{comment} ) =~ s/^($chars)/$1$char /mg;
    $comment .= "\n" if $comment !~ /\n\z/;

    my $c = $self->_read_config($filename);
    $c = '' unless defined $c;

    return $self->_write_config( $filename, $c . $comment );
}

__PACKAGE__->meta->make_immutable;
no Moose;

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

