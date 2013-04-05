package App::Sqitch::Command::rework;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Copy;
use Mouse;
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.961';

has requires => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

has conflicts => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

has note => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

sub options {
    return qw(
        requires|r=s@
        conflicts|c=s@
        note|n=s@
    );
}

sub execute {
    my ( $self, $name ) = @_;
    $self->usage unless defined $name;
    my $sqitch = $self->sqitch;
    my $plan   = $sqitch->plan;

    # Rework it.
    my $reworked = $plan->rework(
        name      => $name,
        requires  => $self->requires,
        conflicts => $self->conflicts,
        note      => join "\n\n" => @{ $self->note },
    );

    # Get the latest instance of the change.
    my $prev = $plan->get(
        $name . [$plan->last_tagged_change->tags]->[-1]->format_name
    );

    # Make sure we have a note.
    $reworked->request_note(
        for     => __ 'rework',
        scripts => [
            (-e $reworked->deploy_file ? $reworked->deploy_file : ()),
            (-e $reworked->revert_file ? $reworked->revert_file : ()),
            (-e $reworked->verify_file ? $reworked->verify_file : ()),
        ],
    );

    # Copy files to the new names for the previous instance of the change.
    my @files = (
        $self->_copy(
            $name,
            $reworked->deploy_file,
            $prev->deploy_file,
        ),
        $self->_copy(
            $name,
            $reworked->revert_file,
            $prev->revert_file,
        ),
        $self->_copy(
            $name,
            $reworked->verify_file,
            $prev->verify_file,
        ),
    );

    # Replace the revert file with the previous deploy file.
    $self->_copy(
        $name,
        $reworked->deploy_file,
        $reworked->revert_file,
        $prev->revert_file,
    );

    # We good, write the plan file back out.
    $plan->write_to( $sqitch->plan_file );

    # Let the user knnow what to do.
    $self->info(__x(
        'Added "{change}" to {file}.',
        change => $reworked->format_op_name_dependencies,
        file   => $sqitch->plan_file,
    ));
    $self->info(__n(
        'Modify this file as appropriate:',
        'Modify these files as appropriate:',
        scalar @files,
    ));
    $self->info("  * $_") for @files;

    return $self;
}

sub _copy {
    my ( $self, $name, $src, $dest, $orig ) = @_;
    $orig ||= $src;
    if (!-e $orig) {
        $self->debug(__x(
            'Skipped {dest}: {src} does not exist',
            dest => $dest,
            src  => $orig,
        ));
        return;
    }

    # Stringify to work around bug in File::Copy warning on 5.10.0.
    File::Copy::syscopy "$src", "$dest" or hurl rework => __x(
        'Cannot copy {src} to {dest}: {error}',
        src   => $src,
        dest  => $dest,
        error => $!,
    );

    $self->debug(__x(
        'Copied {src} to {dest}',
        dest => $dest,
        src  => $src,
    ));
    return $orig;
}

1;

__END__

=head1 Name

App::Sqitch::Command::rework - Rework a Sqitch change

=head1 Synopsis

  my $cmd = App::Sqitch::Command::rework->new(%params);
  $cmd->execute;

=head1 Description

Reworks a new deployment change. This will result in the creation of a scripts
in the deploy, revert, and verify directories. The scripts are based on
L<Template::Tiny> templates in F<~/.sqitch/templates/> or
C<$(etc_path)/templates>.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::rework->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<rework> command.

=head3 C<configure>

  my $params = App::Sqitch::Command::rework->configure(
      $config,
      $options,
  );

Processes the configuration and command options and returns a hash suitable
for the constructor.

=head2 Instance Methods

=head3 C<execute>

  $rework->execute($command);

Executes the C<rework> command.

=head1 See Also

=over

=item L<sqitch-rework>

Documentation for the C<rework> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

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
