package App::Sqitch::Role::ScriptConfigCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use App::Sqitch::Types qw(Maybe Dir Str);
use Path::Class;
use namespace::autoclean;

requires 'options';
requires 'configure';

has reworked_dir => (
    is  => 'ro',
    isa => Maybe[Dir],
);

has extension => (
    is  => 'ro',
    isa => Maybe[Str],
);

for my $script (qw(deploy revert verify)) {
    has "$script\_dir" => (
        is      => 'ro',
        isa     => Maybe[Dir],
    );
    has "reworked_$script\_dir" => (
        is      => 'ro',
        isa     => Maybe[Dir],
        lazy    => 1,
        default => sub {
            my $dir = shift->reworked_dir or return undef;
            $dir->subdir($script);
        },
    );
}

around options => sub {
    my ($orig, $class) = @_;
    return ($class->$orig), qw(
        deploy-dir=s
        revert-dir=s
        verify-dir=s
        reworked-dir=s
        reworked-deploy-dir=s
        reworked-revert-dir=s
        reworked-verify-dir=s
        extension=s
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;

    for my $dir (
        'reworked_dir',
        map { ("$_\_dir", "reworked_$_\_dir") } qw(deploy revert verify)
    ) {
        if ( my $str = $opt->{$dir} ) {
            $opt->{$dir} = dir $str;
        }
    }

    return $class->$orig($config, $opt);
};

sub script_config {
    my $self = shift;
    my $config = {};
    for my $attr (
        'reworked_dir',
        (map { ("$_\_dir", "reworked_$_\_dir") } qw(deploy revert verify)),
        'extension'
    ) {
        if (my $val = $self->$attr) {
            $config->{$attr} = $val;
        }
    }
    return $config;
}

sub directories_for {
    my ($self, $target) = @_;
    return (
        $self->deploy_dir          || $target->deploy_dir,
        $self->revert_dir          || $target->revert_dir,
        $self->verify_dir          || $target->verify_dir,
        $self->reworked_deploy_dir || $target->reworked_deploy_dir,
        $self->reworked_revert_dir || $target->reworked_revert_dir,
        $self->reworked_verify_dir || $target->reworked_verify_dir,
    );
}

1;

__END__

=head1 Name

App::Sqitch::Role::ScriptConfigCommand - A command that reverts and deploys

=head1 Synopsis

  package App::Sqitch::Command::init;
  extends 'App::Sqitch::Command';
  with 'App::Sqitch::Role::ScriptConfigCommand';

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

=head3 C<deploy_dir>

Path to the directory containing deploy scripts.

=head3 C<revert_dir>

Path to the directory containing revert scripts.

=head3 C<verify_dir>

Path to the directory containing verify scripts.

=head3 C<reworked_dir>

Path to the directory containing subdirectories for reworked change scripts.

=head3 C<reworked_deploy_dir>

Path to the directory containing reworked deploy scripts.

=head3 C<reworked_revert_dir>

Path to the directory containing reworked revert scripts.

=head3 C<reworked_verify_dir>

Path to the directory containing reworked verify scripts.

=head3 C<extension>

The file extension to use for change script files.

=head2 Instance Methods

=head3 C<script_config>

  my $config = $cmd->script_config;

Returns a hash reference of script configuration values. They keys are
suitable for use in L<App::Sqitch::Config> sections, while the keys are the
values. All but the C<extension> key are L<Path::Class::Dir> objects.

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
