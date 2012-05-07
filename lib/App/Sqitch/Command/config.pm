package App::Sqitch::Command::config;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Path::Class ();
use Try::Tiny;
use List::Util qw(first);
use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;
extends 'App::Sqitch::Command';

our $VERSION = '0.30';

has file => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $meth = ( $self->context || 'local' ) . '_file';
        return $self->sqitch->config->$meth;
    } );

has action => (
    is  => 'ro',
    isa => enum( [ qw(
                get
                get-all
                get-regex
                set
                unset
                list
                edit
                add
                replace-all
                unset-all
                rename-section
                remove-section
                )
        ] ) );
has context => (
    is  => 'ro',
    isa => maybe_type enum( [ qw(
                local
                user
                system
                )
        ] ) );
has type => ( is => 'ro', isa => enum( [qw(int num bool bool-or-int)] ) );

sub options {
    return qw(
        file|config-file|f=s
        local
        user
        system

        int
        bool
        bool-or-int
        num

        get
        get-all
        get-regex
        add
        replace-all
        unset
        unset-all
        rename-section
        remove-section
        list|l
        edit|e
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    # Make sure we are accessing only one file.
    my @file = grep { $opt->{$_} } qw(local user system file);
    $class->usage('Only one config file at a time.') if @file > 1;

    # Make sure we have only one type.
    my @type = grep { $opt->{$_} } qw(bool int num bool-or-int);
    $class->usage('Only one type at a time.') if @type > 1;

    # Make sure we are performing only one action.
    my @action = grep { $opt->{$_} } qw(
        get
        get-all
        get-regex
        unset
        list
        edit
        add
        replace-all
        unset_all
        rename-section
        remove-section
    );
    $class->usage('Only one action at a time.') if @action > 1;

    # Get the action and context.
    my $context = first { $opt->{$_} } qw(local user system);

    # Make it so.
    return {
        ( $action[0]   ? ( action  => $action[0] )   : () ),
        ( $type[0]     ? ( type    => $type[0] )     : () ),
        ( $context     ? ( context => $context )     : () ),
        ( $opt->{file} ? ( file    => $opt->{file} ) : () ),
    };
}

sub execute {
    my $self = shift;
    my $action = $self->action || ( @_ > 1 ? 'set' : 'get' );
    $action =~ s/-/_/g;
    my $meth = $self->can($action)
        or die 'No method defined for ', $self->action, ' action';

    return $self->$meth(@_);
}

sub get {
    my ( $self, $key, $rx ) = @_;
    $self->usage('Wrong number of arguments.') if !defined $key || $key eq '';

    my $val = try {
        $self->sqitch->config->get(
            key    => $key,
            filter => $rx,
            as     => $self->type,
            human  => 1,
        );
    }
    catch {
        $self->fail(qq{More then one value for the key "$key"})
            if /^\QMultiple values/i;
        $self->fail($_);
    };

    $self->unfound unless defined $val;
    $self->emit($val);
    return $self;
}

sub get_all {
    my ( $self, $key, $rx ) = @_;
    $self->usage('Wrong number of arguments.') if !defined $key || $key eq '';

    my @vals = try {
        $self->sqitch->config->get_all(
            key    => $key,
            filter => $rx,
            as     => $self->type,
            human  => 1,
        );
    }
    catch {
        $self->fail($_);
    };
    $self->unfound unless @vals;
    $self->emit( join $/, @vals );
    return $self;
}

sub get_regex {
    my ( $self, $key, $rx ) = @_;
    $self->usage('Wrong number of arguments.') if !defined $key || $key eq '';

    my $config = $self->sqitch->config;
    my %vals   = try {
        $config->get_regexp(
            key    => $key,
            filter => $rx,
            as     => $self->type,
            human  => 1,
        );
    }
    catch {
        $self->fail($_);
    };
    $self->unfound unless %vals;
    my @out;
    for my $key ( sort keys %vals ) {
        if ( defined $vals{$key} ) {
            if ( $config->is_multiple($key) ) {
                push @out => "$key=[" . join( ', ', @{ $vals{$key} } ) . ']';
            }
            else {
                push @out => "$key=$vals{$key}";
            }
        }
        else {
            push @out => $key;
        }
    }
    $self->emit( join $/ => @out );

    return $self;
}

sub set {
    my ( $self, $key, $value, $rx ) = @_;
    $self->_set( $key, $value, $rx, multiple => 0 );
}

sub add {
    my ( $self, $key, $value ) = @_;
    $self->_set( $key, $value, undef, multiple => 1 );
}

sub replace_all {
    my ( $self, $key, $value, $rx ) = @_;
    $self->_set( $key, $value, $rx, multiple => 1, replace_all => 1 );
}

sub _set {
    my ( $self, $key, $value, $rx, @p ) = @_;
    $self->usage('Wrong number of arguments.')
        if !defined $key || $key eq '' || !defined $value;

    $self->_touch_dir;
    try {
        $self->sqitch->config->set(
            key      => $key,
            value    => $value,
            filename => $self->file,
            filter   => $rx,
            as       => $self->type,
            @p,
        );
    }
    catch {
        $self->fail('Cannot overwrite multiple values with a single value')
            if /^Multiple occurrences/i;
        $self->fail($_);
    };
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
    my ( $self, $key, $rx ) = @_;
    $self->usage('Wrong number of arguments.') if !defined $key || $key eq '';
    $self->_touch_dir;

    try {
        $self->sqitch->config->set(
            key      => $key,
            filename => $self->file,
            filter   => $rx,
            multiple => 0,
        );
    }
    catch {
        $self->fail('Cannot unset key with multiple values')
            if /^Multiple occurrences/i;
        $self->fail($_);
    };
    return $self;
}

sub unset_all {
    my ( $self, $key, $rx ) = @_;
    $self->usage('Wrong number of arguments.') if !defined $key || $key eq '';

    $self->_touch_dir;
    $self->sqitch->config->set(
        key      => $key,
        filename => $self->file,
        filter   => $rx,
        multiple => 1,
    );
    return $self;
}

sub list {
    my $self = shift;
    my $config =
          $self->context
        ? $self->_file_config
        : $self->sqitch->config;
    $self->emit( scalar $config->dump ) if $config;
    return $self;
}

sub edit {
    my $self = shift;

    # Let the editor deal with locking.
    $self->run( $self->sqitch->editor, $self->file );
}

sub rename_section {
    my ( $self, $old_name, $new_name ) = @_;
    unless ( defined $old_name
        && $old_name ne ''
        && defined $new_name
        && $new_name ne '' )
    {
        $self->usage('Wrong number of arguments.');
    }

    try {
        $self->sqitch->config->rename_section(
            from     => $old_name,
            to       => $new_name,
            filename => $self->file
        );
    }
    catch {
        $self->fail('No such section!') if /\Qno such section/i;
        $self->fail($_);
    };
    return $self;
}

sub remove_section {
    my ( $self, $section ) = @_;
    $self->usage('Wrong number of arguments.')
        unless defined $section && $section ne '';
    try {
        $self->sqitch->config->remove_section(
            section  => $section,
            filename => $self->file
        );
    }
    catch {
        $self->fail('No such section!') if /\Qno such section/i;
        die $_;
    };
    return $self;
}

sub _touch_dir {
    my $self = shift;
    unless ( -e $self->file ) {
        require File::Basename;
        my $dir = File::Basename::dirname( $self->file );
        unless ( -e $dir && -d _ ) {
            require File::Path;
            File::Path::make_path($dir);
        }
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Command::config - Get and set local, user, or system Sqitch
options

=head1 Synopsis

  my $cmd = App::Sqitch::Command::config->new(\%params);
  $cmd->execute;

=head1 Description

You can query/set/replace/unset Sqitch options with this command. The name is
actually the section and the key separated by a dot, and the value will be
escaped.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::config->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<config> command.

=head3 C<configure>

  my $params = App::Sqitch::Command::config->configure(
      $config,
      $options,
  );

Processes the configuration and command options and returns a hash suitable
for the constructor. Exits with an error on option specification errors.

=head2 Constructor

=head3 C<new>

  my $config = App::Sqitch::Command::config->new($params);

Creates and returns a new C<config> command object. The supported parameters
include:

=over

=item C<sqitch>

The core L<Sqitch|App::Sqitch> object.

=item C<file>

Configuration file to read from and write to.

=item C<action>

The action to be executed. May be one of:

=over

=item * C<get>

=item * C<get-all>

=item * C<get-regex>

=item * C<set>

=item * C<add>

=item * C<replace-all>

=item * C<unset>

=item * C<unset-all>

=item * C<list>

=item * C<edit>

=item * C<rename-section>

=item * C<remove-section>

=back

If not specified, the action taken by C<execute()> will depend on the number
of arguments passed to it. If only one, the action will be C<get>. If two or
more, the action will be C<set>.

=item C<context>

The configuration file context. Must be one of:

=over

=item * C<local>

=item * C<user>

=item * C<system>

=back

=item C<type>

The type to cast a value to be set to or fetched as. May be one of:

=over

=item * C<bool>

=item * C<int>

=item * C<num>

=item * C<bool-or-int>

=back

If not specified or C<undef>, no casting will be performed.

=back

=head2 Instance Methods

These methods are mainly provided as utilities for the command subclasses to
use.

=head3 C<execute>

  $config->execute($property, $value);

Executes the config command. Pass the name of the property and the value to
be assigned to it, if applicable.

=head3 C<get>

  $config->get($key);
  $config->get($key, $regex);

Emits the value for the specified key. The optional second argument is a
regular expression that the value to be returned must match. Exits with an
error if the is more than one value for the specified key, or if the key does
not exist.

=head3 C<get_all>

  $config->get_all($key);
  $config->get_all($key, $regex);

Like C<get()>, but emits all of the values for the given key, rather then
exiting with an error when there is more than one value.

=head3 C<get_regex>

  $config->get_regex($key);
  $config->get_regex($key, $regex);

Like C<get_all()>, but the first parameter is a regular expression that will
be matched against all keys.

=head3 C<set>

  $config->set($key, $value);
  $config->set($key, $value, $regex);

Sets the value for a key. Exits with an error if the key already exists and
has multiple values.

=head3 C<add>

  $config->add($key, $value);

Adds a value for a key. If the key already exists, the value will be added as
an additional value.

=head3 C<replace_all>

  $config->replace_all($key, $value);
  $config->replace_all($key, $value, $regex);

Replace all matching values.

=head3 C<unset>

  $config->unset($key);
  $config->unset($key, $regex);

Unsets a key. If the optional second argument is passed, the key will be
unset only if the value matches the regular expression. If the key has
multiple values, C<unset()> will exit with an error.

=head3 C<unset_all>

  $config->unset_all($key);
  $config->unset_all($key, $regex);

Like C<unset()>, but will not exit with an error if the key has multiple
values.

=head3 C<rename_section>

  $config->rename_section($old_name, $new_name);

Renames a section. Exits with an error if the section does not exist or if
either name is not a valid section name.

=head3 C<remove_section>

  $config->remove_section($section);

Removes a section. Exits with an error if the section does not exist.

=head3 C<list>

  $config->list;

Lists all of the values in the configuration. If the context is C<local>,
C<user>, or C<system>, only the settings set for that context will be
emitted. Otherwise, all settings will be listed.

=head3 C<edit>

  $config->edit;

Opens the context-specific configuration file in a text editor for direct
editing. If no context is specified, the local config file will be opened.
The editor is determined by L<Sqitch/editor>.

=head2 Instance Accessors

=head3 C<file>

  my $file_name = $config->file;

Returns the path to the configuration file to be acted upon. If the context
is C<system>, then the value returned is C<$($etc_prefix)/sqitch.conf>. If
the context is C<user>, then the value returned is C<~/.sqitch/sqitch.conf>.
Otherwise, the default is F<./sqitch.conf>.

=head1 See Also

=over

=item L<sqitch-config>

Help for the C<config> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 To Do

=over

=item * Make exit codes the same as C<git-config>.

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

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut

