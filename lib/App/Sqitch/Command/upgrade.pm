package App::Sqitch::Command::upgrade;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(URI Maybe Str Bool HashRef);
use Locale::TextDomain qw(App-Sqitch);
use Type::Utils qw(enum);
use App::Sqitch::X qw(hurl);
use List::Util qw(first);
use namespace::autoclean;
extends 'App::Sqitch::Command';

our $VERSION = '0.9992';

has target => (
    is  => 'ro',
    isa => Str,
);

sub options {
    return qw(
        target|t=s
    );
}

sub execute {
    my ( $self, $target ) = @_;

    # Need to set up the target before we do anything else.
    if (my $t = $self->target // $target) {
        $self->warn(__x(
            'Both the --target option and the target argument passed; using {option}',
            option => $self->target,
        )) if $target && $self->target;
        require App::Sqitch::Target;
        $target = App::Sqitch::Target->new(sqitch => $self->sqitch, name => $t);
    } else {
        $target = $self->default_target;
    }
    my $engine = $target->engine;

    if ($engine->needs_upgrade) {
        $self->info( __x(
            'Upgrading registry {registry} to version {version}',
            registry => $engine->registry_destination,
            version  => $engine->registry_release,
        ));
        $engine->upgrade_registry;
    } else {
        $self->info( __x(
            'Registry {registry} is up-to-date at version {version}',
            registry => $engine->registry_destination,
            version  => $engine->registry_release,
        ));
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::upgrade - Upgrade the Sqitch registry

=head1 Synopsis

  my $cmd = App::Sqitch::Command::upgrade->new(%params);
  $cmd->execute;

=head1 Description

If you want to know how to use the C<upgrade> command, you probably want to be
reading C<sqitch-upgrade>. But if you really want to know how the C<upgrade>
command works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::upgrade->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<upgrade> command.

=head2 Attributes

=head3 C<target>

The upgrade target.

=head2 Instance Methods

=head3 C<execute>

  $upgrade->execute;

Executes the upgrade command.

=head1 See Also

=over

=item L<sqitch-upgrade>

Documentation for the C<upgrade> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

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
