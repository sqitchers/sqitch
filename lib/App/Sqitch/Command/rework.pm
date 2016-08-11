package App::Sqitch::Command::rework;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Copy;
use Moo;
use App::Sqitch::Types qw(Str ArrayRef Bool Maybe);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.9996';

has change_name => (
    is  => 'ro',
    isa => Maybe[Str],
);

has requires => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has conflicts => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has all => (
    is      => 'ro',
    isa     => Bool,
    default => 0
);

has note => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has open_editor => (
    is       => 'ro',
    isa      => Bool,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return $self->sqitch->config->get(
            key => 'rework.open_editor',
            as  => 'bool',
        ) // $self->sqitch->config->get(
            key => 'add.open_editor',
            as  => 'bool',
        ) // 0;
    },
);

sub options {
    return qw(
        change-name|change|c=s
        requires|r=s@
        conflicts|x=s@
        all|a!
        note|n|m=s@
        open-editor|edit|e!
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;
    # Just keep the options.
    return $opt;
}

sub execute {
    my $self = shift;
    my ($name, $targets, $changes) = $self->parse_args(
        names      => [$self->change_name],
        all        => $self->all,
        args       => \@_,
        no_default => 1,
        no_changes => 1,
    );

    # Check if the name is identified as a change.
    $name ||= shift @{ $changes } || $self->usage;

    my $note = join "\n\n", => @{ $self->note };
    my ($first_change, %reworked, @files, %seen);

    for my $target (@{ $targets }) {
        my $plan   = $target->plan;
        my $file = $plan->file;
        my $spec = $reworked{$file} ||= { scripts => [] };
        my ($prev, $reworked);
        if ($prev = $spec->{prev}) {
            # Need a dupe for *this* target so script names are right.
            $reworked = ref($prev)->new(
                plan => $plan,
                name => $name,
            );

            # Copy the rework tags to the previous instance in this plan.
            my $new_prev = $spec->{prev} = $plan->get(
                $name . [$plan->last_tagged_change->tags]->[-1]->format_name
            );
            $new_prev->add_rework_tags($prev->rework_tags);
            $prev = $new_prev;

        } else {
            # Rework it.
            $reworked = $spec->{change} = $plan->rework(
                name      => $name,
                requires  => $self->requires,
                conflicts => $self->conflicts,
                note      => $note,
            );
            $first_change ||= $reworked;

            # Get the latest instance of the change.
            $prev = $spec->{prev} = $plan->get(
                $name . [$plan->last_tagged_change->tags]->[-1]->format_name
            );
        }

        # Record the files to be copied to the previous change name.
        push @{ $spec->{scripts} } => map {
            push @files => $_->[0] if -e $_->[0];
            $_;
        } grep {
            !$seen{ $_->[0] }++;
        } (
            [ $reworked->deploy_file, $prev->deploy_file ],
            [ $reworked->revert_file, $prev->revert_file ],
            [ $reworked->verify_file, $prev->verify_file ],
        );

        # Replace the revert file with the previous deploy file.
        push @{ $spec->{scripts} } => [
            $reworked->deploy_file,
            $reworked->revert_file,
            $prev->revert_file,
        ] unless $seen{$prev->revert_file}++;
    }

    # Make sure we have a note.
    $note = $first_change->request_note(
        for     => __ 'rework',
        scripts => \@files,
    );

    # Time to write everything out.
    for my $target (@{ $targets }) {
        my $plan = $target->plan;
        my $file = $plan->file;
        my $spec = delete $reworked{$file} or next;

        # Copy the files for this spec.
        $self->_copy(@{ $_ }) for @{ $spec->{scripts } };

        # We good, write the plan file back out.
        $plan->write_to( $plan->file );

        # Let the user know.
        $self->info(__x(
            'Added "{change}" to {file}.',
            change => $spec->{change}->format_op_name_dependencies,
            file   => $plan->file,
        ));
    }

    # Now tell them what to do.
    $self->info(__n(
        'Modify this file as appropriate:',
        'Modify these files as appropriate:',
        scalar @files,
    ));
    $self->info("  * $_") for @files;

    # Let 'em at it.
    if ($self->open_editor) {
        my $sqitch = $self->sqitch;
        $sqitch->shell( $sqitch->editor . ' ' . $sqitch->quote_shell(@files) );
    }

    return $self;
}

sub _copy {
    my ( $self, $src, $dest, $orig ) = @_;
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

Reworks a change. This will result in the copying of the existing deploy,
revert, and verify scripts for the change to preserve the earlier instances of
the change.

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

=head2 Attributes

=head3 C<change_name>

The name of the change to be reworked.

=head3 C<note>

Text of the change note.

=head3 C<requires>

List of required changes.

=head3 C<conflicts>

List of conflicting changes.

=head3 C<all>

Boolean indicating whether or not to run the command against all plans in the
project.

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
