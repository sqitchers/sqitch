package App::Sqitch::Role::TargetConfigCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use App::Sqitch::Types qw(Maybe HashRef Str);
use App::Sqitch::X qw(hurl);
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use List::Util qw(first);
use File::Path qw(make_path);
use namespace::autoclean;

requires 'command';
requires 'options';
requires 'configure';
requires 'sqitch';
requires 'property_keys';

has properties => (
    is  => 'ro',
    isa => HashRef,
    default => sub { {} },
);

around options => sub {
    my ($orig, $class) = @_;
    return ($class->$orig), qw(set|s=s%);
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;
    my $set = delete $opt->{set};
    my $params = $class->$orig($config, $opt);

    if ($set) {
        # Make sure we ahve only allowed keys.
        my $ok_keys = { map { $_ => undef } $class->property_keys };
        if (my @keys = grep { !exists $ok_keys->{$_} } keys %{ $set }) {
            hurl $class->command => __nx(
                'Unknown property name: {props}',
                'Unknown property names: {props}',
                @keys,
                props => join(__ ', ', sort @keys),
            );
        }

        # Copy plain string properties.
        my $props = {};
        for my $name (qw(engine extension target registry)) {
            $props->{$name} = delete $set->{$name} if exists $set->{$name};
        }

        # Convert file properties to Class::Path::File objects.
        for my $name (qw(plan_file client)) {
            if ( my $file = delete $set->{$name} ) {
                $props->{$name} = file($file)->cleanup;
            }
        }

        # Convert directory properties to Class::Path::Dir objects.
        for my $name (qw(
            top_dir
            deploy_dir
            revert_dir
            verify_dir
            reworked_dir
            reworked_deploy_dir
            reworked_revert_dir
            reworked_verify_dir
        )) {
            if ( my $dir = delete $set->{$name} ) {
                $props->{$name} = dir($dir)->cleanup;
            }
        }

        $params->{properties} = $props;
    }

    return $params;
};

sub BUILD {
    my $self = shift;
    my $props = $self->properties;

    if (my $engine = $props->{engine}) {
        # Validate engine.
        hurl $self->command => __x(
            'Unknown engine "{engine}"', engine => $engine
        ) unless first { $engine eq $_ } App::Sqitch::Command::ENGINES;
    }

    # Copy core options.
    my $opts = $self->sqitch->options;
    for my $name (qw(
        top_dir
        plan_file
        engine
        registry
        client
        target
        extension
        deploy_dir
        revert_dir
        verify_dir
    )) {
        $props->{$name} ||= $opts->{$name} if exists $opts->{$name};
    }
}

sub directories_for {
    my $self = shift;
    my $props = $self->properties;
    my (@dirs, %seen);

    for my $target (@_) {
        # Script directories.
        if (my $top_dir = $props->{top_dir}) {
            push @dirs => grep { !$seen{$_}++ } map {
                $props->{"$_\_$_"} || $top_dir->subdir($_);
            } qw(deploy revert verify);
        } else {
            push @dirs => grep { !$seen{$_}++ } map {
                my $name = "$_\_dir";
                $props->{$name} || $target->$name;
            } qw(deploy revert verify);
        }

        # Reworked script directories.
        if (my $reworked_dir = $props->{reworked_dir} || $props->{top_dir}) {
            push @dirs => grep { !$seen{$_}++ } map {
                $props->{"reworked_$_\_dir"} || $reworked_dir->subdir($_);
            } qw(deploy revert verify);
        } else {
            push @dirs => grep { !$seen{$_}++ } map {
                my $name = "reworked_$_\_dir";
                $props->{$name} || $target->$name;
            } qw(deploy revert verify);
        }
    }

    return @dirs;
}

sub make_directories_for {
    my $self  = shift;
    $self->mkdirs( $self->directories_for(@_) );
}

sub mkdirs {
    my $self = shift;

    for my $dir (@_) {
        my $sep = dir('')->stringify; # OS-specific directory separator.
        $self->info(__x(
            'Created {file}',
            file => "$dir$sep"
        )) if make_path $dir, { error => \my $err };
        if ( my $diag = shift @{ $err } ) {
            my ( $path, $msg ) = %{ $diag };
            hurl $self->command => __x(
                'Error creating {path}: {error}',
                path  => $path,
                error => $msg,
            ) if $path;
            hurl $self->command => $msg;
        }
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Role::TargetConfigCommand - A command that handles target-related configuration

=head1 Synopsis

  package App::Sqitch::Command::init;
  extends 'App::Sqitch::Command';
  with 'App::Sqitch::Role::TargetConfigCommand';

=head1 Description

This role encapsulates the common attributes and methods required by commands
that deal with change script configuration, including script directories and
extensions.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::checkout->options;

Adds options common to the commands that manage script configuration.

=head3 C<configure>

Configures the options common to commands manage script configuration.

=head2 Attributes

=head3 C<properties>

A hash reference of target configurations. The keys may be as follows:

=over

=item C<deploy>

=item C<revert>

=item C<verify>

=item C<reworked>

=item C<reworked_deploy>

=item C<reworked_revert>

=item C<reworked_verify>

=item C<extension>

=back

=head2 Instance Methods

=head3 C<directories_for>

  my @dirs = $cmd->directories_for(@targets);

Returns a set of script directories for a list of targets. Options passed to
the command are preferred. Paths are pulled from the command only when they
have not been passed as options.

=head3 C<make_directories_for>

  $cmd->directories_for(@targets);
n
Creates scipt directories for one or more targets. Options passed to the
command are preferred. Paths are pulled from the command only when they have
not been passed as options.

=head3 C<mkdirs>

   $cmd->directories_for(@dirs);

Creates the list of directories on the file system. Messages are sent to
C<info()> for each directory, and an error is thrown on the first to fail.

=head1 See Also

=over

=item L<App::Sqitch::Command::init>

The C<init> command initializes a Sqitch project, setting up the change script
configuration and directories.

=item L<App::Sqitch::Command::engine>

The C<engine> command manages engine configuration, including engine-specific
change script configuration.

=item L<App::Sqitch::Command::target>

The C<engine> command manages target configuration, including target-specific
change script configuration.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2015 iovation Inc.

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
