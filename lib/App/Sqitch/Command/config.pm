package App::Sqitch::Command::config;

use v5.10;
use strict;
use warnings;
use utf8;
use Carp;
use Config::INI;
use parent 'App::Sqitch::Command';

our $VERSION = '0.10';

__PACKAGE__->mk_ro_accessors(qw(
    get
    user
    system
    config_file
    unset
    list
    edit
));

sub options {
    return qw(
        get
        user
        system
        config-file|file|f=s
        unset
        list|l
        edit|e
    );
}

sub execute {
    my ($self, $key, $value) = @_;
}

sub read_config {
    my $self = shift;
}

sub write_config {
    my $self = shift;
}

sub config_file {
    my $self = shift;
    return $self->{config_file} ||= do {
        require File::Spec;
        if ($self->system) {
            require Config;
            File::Spec->catfile($Config::Config{prefix}, 'etc', 'sqitch.ini')
        } else {
            File::Spec->catfile(
                $self->user ? ($self->sqitch->_user_config_root, 'config.ini')
                            : (File::Spec->curdir, 'sqitch.ini')
            );
        }
    };
}

1;

__END__

=head1 Name

App::Sqitch::Command::config - Get and set project or global Sqitch options

=head1 Synopsis

  my $cmd = App::Sqitch::Command::config->new(\%params);
  $cmd->execute;

=head1 Description

You can query/set/replace/unset Sqitch options with this command. The name is
actually the section and the key separated by a dot, and the value will be
escaped.

=head1 Interface

=head2 Class Methods

=head3 options

  my @opts = App::Sqitch::Command::config->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<config> command.

=head2 Constructor

=head3 C<new>

  my $config = App::Sqitch::Command::config->new($params);

Creates and returns a new C<config> command object. The supported parameters
include:

=over

=item C<sqitch>

The core L<Sqitch|App::Sqitch> object.

=item C<get>

Boolean indicating whether to get a value.

=item C<user>

Boolean indicating whether to use the user configuration file.

=item C<system>

Boolean indicating whether to use the system configuration file.

=item C<config_file>

Configuration file to read from and write to.

=item C<unset>

Boolean indicating that the specified value should be removed from the
configuration file.

=item C<list>

Boolean indicating that a list of the settings should be returned from
the configuration file.

=item C<edit>

Boolean indicating the the configuration file contents should be opened
in an editor.

=back

=head2 Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<execute>

  $config->execute($property, $value);

Executes the config command. Pass the name of the property and the value to
be assigned to it, if applicable.

=head3 C<config_file>

  my $file_name = $config->config_file;

Returns the path to the configuration file to be acted upon. If the C<system>
attribute is true, then the value returned is C<$(prefix)/etc/sqitch.ini>. If
the C<user> attribute is true, then the value returned is
C<~/.sqitch.config.ini>. Otherwise, the default is F<./sqitch.ini>.

=head3 C<read_config>

  my $config_data = $config->read_config;

Reads the configuration file returned by C<config_file>, parses it into a
hash, and returns the hash.

=head3 C<write_config>

  $config->write_config($config_data);

Writes the configuration data to the configuration file returned by
C<config_file>.

=head1 See Also

=over

=item L<sqitch-config>

Help for the C<config> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

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

