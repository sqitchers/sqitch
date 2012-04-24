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
        get-all
        get-regexp
        add
        unset
        unset-all
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
    my @action = grep { $p->{$_} } qw(get get_all get_regexp unset list edit add unset_all);
    $class->usage('Only one action at a time.') if @action > 1;

    # Get the file.
    my $file = $p->{file} || do {
        if ($p->{system}) {
            $p->{sqitch}->config->global_file
        } elsif ($p->{user}) {
            $p->{sqitch}->config->user_file
        } else {
            $p->{sqitch}->config->dir_file
        }
    };

    # Get the action and context.
    my $context = first { $p->{$_} } qw(user system);

    return $class->SUPER::new({
        sqitch  => $p->{sqitch},
        action  => $action[0] || 'set',
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

sub get {
    my ($self, $key, $rx) = @_;
    if (my $config = $self->_file_config) {
        my @vals = $config->get_all(key => $key, filter => $rx);
        $self->fail("Cannot unset key with multiple values") if @vals > 1;
    }
    my $val = $self->sqitch->config->get(key => $key, filter => $rx);
    $self->unfound unless defined $val;
    $self->emit($val);
    return $self;
}

sub get_all {
    my ($self, $key, $rx) = @_;
    my @vals = $self->sqitch->config->get_all(key => $key, filter => $rx);
    $self->unfound unless @vals;
    $self->emit(join $/, @vals);
    return $self;
}

sub get_regexp {
    my ($self, $key, $rx) = @_;
    my $config = $self->sqitch->config;
    my %vals = $config->get_regexp(key => $key, filter => $rx);
    $self->unfound unless %vals;
    my @out;
    for my $key (sort keys %vals) {
        if (defined $vals{$key}) {
            if ( $config->is_multiple($key) ) {
                push @out => "$key=[" . join(', ', @{$vals{$key}}) . ']';
            }
            else {
                push @out => "$key=$vals{$key}";
            }
        } else {
            push @out => $key;
        }
    }
    $self->emit(join $/ => @out);

    return $self;
}

sub set { shift->_set(@_, 0) }
sub add { shift->_set(@_, 1) }

sub _set {
    my ($self, $key, $value, $mult) = @_;
    $self->_touch_dir;
    $self->sqitch->config->set(
        key      => $key,
        value    => $value,
        filename => $self->file,
        multiple => $mult,
    );
    return $self;
}

sub _file_config {
    my $file = shift->file;
    return unless -e $file;
    my $config = App::Sqitch::Config->new;
    $config->load_file($file);
    return $config;
}

sub unset {
    my ($self, $key) = @_;
    my @vals = $self->_file_config->get_all(key => $key);
    $self->fail("Cannot unset key with multiple values") if @vals > 1;
    $self->_touch_dir;

    $self->sqitch->config->set(
        key      => $key,
        filename => $self->file,
    ) if @vals;
    return $self;
}

sub unset_all {
    my ($self, $key) = @_;
    $self->_touch_dir;
    $self->sqitch->config->set(
        key      => $key,
        filename => $self->file,
        multiple => 1,
    );
    return $self;
}

sub list {
    my $self = shift;
    my $config = $self->context eq 'project'
        ? $self->sqitch->config
        : $self->_file_config;
    $self->emit(scalar $config->dump) if $config;
    return $self;
}

sub edit {
    my $self = shift;
    # Let the editor deal with locking.
    $self->do_system($self->sqitch->editor, $self->file) or $self->fail;
}

sub _touch_dir {
    my $self = shift;
    unless (-e $self->file) {
        require File::Basename;
        my $dir = File::Basename::dirname($self->file);
        unless (-e $dir && -d _) {
            require File::Path;
            File::Path::make_path($dir);
        }
    }
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

Boolean indicating whether to get a single value.

=item C<get_all>

Boolean indicating whether to get all instances of a multiple value.

=item C<get_regexp>

Boolean indicating whether to get all instances matching a regular expression.

=item C<set>

Boolean indicating whether to set a value. This is the default action if
no other action is specified.

=item C<add>

Boolean indicating whether to a new line to the option without altering any
existing values.

=item C<user>

Boolean indicating whether to use the user configuration file.

=item C<system>

Boolean indicating whether to use the system configuration file.

=item C<file>

Configuration file to read from and write to.

=item C<unset>

Boolean indicating that the specified single-value key should be removed from
the configuration file.

=item C<unset_all>

Boolean indicating that the specified multiple-value key should be removed
from the configuration file.

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

=head1 See Also

=over

=item L<sqitch-config>

Help for the C<config> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 To Do

=over

=item * Add data type support like git-config?

=item * Add C<--remove-section> and C<--rename-section>.

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

