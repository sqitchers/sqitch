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
use namespace::autoclean;

requires 'command';
requires 'options';
requires 'configure';

has directories => (
    is  => 'ro',
    isa => HashRef,
    default => sub { {} },
);

has extension => (
    is  => 'ro',
    isa => Maybe[Str],
);

around options => sub {
    my ($orig, $class) = @_;
    return ($class->$orig), qw(
        directory|dir=s%
        extension=s
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;
    my $dirs = delete $opt->{directory};
    my $ext  = delete $opt->{extension};
    my $params = $class->$orig($config, $opt);
    $params->{extension} = $ext if defined $ext;

    if ($dirs) {
        my $cdirs = {};
        for my $name (qw(
            deploy
            revert
            verify
            reworked
            reworked_deploy
            reworked_revert
            reworked_verify
        )) {
            if ( my $dir = delete $dirs->{$name} ) {
                $cdirs->{$name} = dir $dir;
            }
        }

        if (my @keys = keys %{ $dirs }) {
            hurl $class->command => __nx(
                'Unknown directory name: {dirs}',
                'Unknown directory names: {dirs}',
                @keys,
                dirs => join(__ ', ', sort @keys),
            );
        }

        $params->{directories} = $cdirs;
    }

    return $params;
};

sub BUILD {
    my $self = shift;
    my $dirs = $self->directories;
    if (my $reworked = $dirs->{reworked}) {
        # Generate reworked script directories.
        for my $name (qw(deploy revert verify)) {
            $dirs->{"reworked_$name"} ||= $reworked->subdir($name);
        }
    }
}

sub directories_for {
    my ($self, $target) = @_;
    my $dirs = $self->directories;
    return (
        $dirs->{deploy}          || $target->deploy_dir,
        $dirs->{revert}          || $target->revert_dir,
        $dirs->{verify}          || $target->verify_dir,
        $dirs->{reworked_deploy} || $target->reworked_deploy_dir,
        $dirs->{reworked_revert} || $target->reworked_revert_dir,
        $dirs->{reworked_verify} || $target->reworked_verify_dir,
    );
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

=head3 C<directories>

A hash reference of directory configurations. The keys may be as follows:

=over

=item C<deploy>

=item C<revert>

=item C<verify>

=item C<reworked>

=item C<reworked_deploy>

=item C<reworked_revert>

=item C<reworked_verify>

=back

=head3 C<extension>

The file extension to use for change script files.

=head2 Instance Methods

=head3 C<directories_for>

  my @dirs = $cmd->directories_for($target);

Returns a list of script directories for the target. Options passed to the
command are preferred. Paths are pulled from the command only when they have
not been passed as options.

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
