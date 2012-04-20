package App::Sqitch::Command::config;

use v5.10;
use strict;
use warnings;
use utf8;
use Carp;
use Path::Class ();
use List::Util qw(sum first);
use parent 'App::Sqitch::Command';

our $VERSION = '0.10';

__PACKAGE__->mk_ro_accessors(qw(
    file
    action
    context
));

sub options {
    return qw(
        file|config-file|f=s
        user
        system

        get
        unset
        list|l
        edit|e
    );
}

sub new {
    my ($class, $p) = @_;

    # Make sure we are accessing only one file.
    my $file_count = sum map { !!$p->{$_} } qw(user system file);
    $class->usage('Only one config file at a time.') if $file_count > 1;

    # Make sure we are performing only one action.
    my $action_count = sum map { !!$p->{$_} } qw(get unset list edit);
    $class->usage('Only one action at a time.') if $action_count > 1;

    # Get the file.
    my $file = $p->{file} || do {
        if ($p->{system}) {
            Path::Class::file($p->{sqitch}->_system_config_root, 'sqitch.ini');
        } elsif ($p->{user}) {
            Path::Class::file($p->{sqitch}->_user_config_root, 'config.ini');
        } else {
            Path::Class::file(+File::Spec->curdir, 'sqitch.ini');
        }
    };

    # Get the action and context.
    my $action  = first { $p->{$_} } qw(get unset list edit);
    my $context = first { $p->{$_} } qw(user system);

    return $class->SUPER::new({
        sqitch  => $p->{sqitch},
        action  => $action  || 'set',
        context => $context || 'project',
        file    => $file,
    });
}

sub execute {
    my $self = shift;
    my $meth = $self->can($self->action)
        or die 'No method defined for ', $self->action, ' action';

    return $self->$meth(@_)
}

sub _config_for_reading {
    my $self = shift;
    return $self->sqitch->config if $self->context eq 'project';
    return $self->read_config;
}

sub get {
    my ($self, $key) = @_;
    my ($section, $prop) = $self->_parse_key($key);
    my $config = $self->_config_for_reading;
    $self->fail unless defined $config->{$section}{$prop};
    $self->emit($config->{$section}{$prop});
    return $self;
}

sub set {
    my ($self, $key, $value) = @_;
    my ($section, $prop) = $self->_parse_key($key);
    $self->lock_config;
    my $config = $self->read_config;
    $config->{$section}{$prop} = $value;
    $self->write_config($config);
}

sub unset {
    my ($self, $key) = @_;
    my ($section, $prop) = $self->_parse_key($key);
    $self->lock_config;
    my $config = $self->read_config;
    delete $config->{$section}{$prop};
    $self->write_config($config);
}

sub list {
    my $self = shift;
    my $config = $self->_config_for_reading;
    for my $section ( sort keys %{ $config }) {
        for my $key ( sort keys %{ $config->{$section} } ) {
            $self->emit("$section.$key=", $config->{$section}{$key});
        }
    }
    return $self;
}

sub edit {
    my $self = shift;
    $self->lock_config;
    my $editor = $self->sqitch->editor;
    system $editor, $self->file;
}

sub read_config {
    my $self = shift;
    my $fn = $self->file;
    return {} unless -f $fn;
    require Config::INI::Reader;
    return Config::INI::Reader->read_file($fn);
}

sub write_config {
    my ($self, $config) = @_;
    require Config::INI::Writer;
    Config::INI::Writer->write_file($config, $self->file);
}

sub lock_config {
}

sub _parse_key {
    my $self = shift;
    my $key = shift or $self->usage('Wrong number of arguments');
    my @parts = split /[.]/ => $key;
    my $var = pop @parts;
    $self->fail(qq{Property key does not contain a section: "$var"})
        unless @parts;
    return join('.' => @parts), $var;
}

1;

__END__

=head1 Name

App::Sqitch::Command::config - Get and set project, user, or system Sqitch options

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

=item C<set>

Boolean indicating whether to set a value. This is the default action if
no other action is specified.

=item C<user>

Boolean indicating whether to use the user configuration file.

=item C<system>

Boolean indicating whether to use the system configuration file.

=item C<file>

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

=head3 C<file>

  my $file_name = $config->file;

Returns the path to the configuration file to be acted upon. If the C<system>
attribute is true, then the value returned is C<$(prefix)/etc/sqitch.ini>. If
the C<user> attribute is true, then the value returned is
C<~/.sqitch.config.ini>. Otherwise, the default is F<./sqitch.ini>.

=head3 C<read_config>

  my $config_data = $config->read_config;

Reads the configuration file returned by C<file>, parses it into a hash, and
returns the hash.

=head3 C<write_config>

  $config->write_config($config_data);

Writes the configuration data to the configuration file returned by C<file>.

=head3 C<lock_config>

  $config->lock_config;

Reads the configuration file returned by C<file>. If a lock cannot be created,
the command will exit with a failure message.

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

