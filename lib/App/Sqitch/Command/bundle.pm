package App::Sqitch::Command::bundle;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(Str Dir Maybe Bool);
use File::Path qw(make_path);
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Copy ();
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.9999';

has from => (
    is       => 'ro',
    isa      => Maybe[Str],
);

has to => (
    is       => 'ro',
    isa      => Maybe[Str],
);

has dest_dir => (
    is       => 'ro',
    isa      => Dir,
    lazy     => 1,
    default  => sub { dir 'bundle' },
);

has all => (
    is      => 'ro',
    isa     => Bool,
    default => 0
);

sub dest_top_dir {
    my $self = shift;
    dir $self->dest_dir, shift->top_dir->relative;
}

sub dest_dirs_for {
    my ($self, $target) = @_;
    my $dest = $self->dest_dir;
    return {
        deploy          => dir($dest, $target->deploy_dir->relative),
        revert          => dir($dest, $target->revert_dir->relative),
        verify          => dir($dest, $target->verify_dir->relative),
        reworked_deploy => dir($dest, $target->reworked_deploy_dir->relative),
        reworked_revert => dir($dest, $target->reworked_revert_dir->relative),
        reworked_verify => dir($dest, $target->reworked_verify_dir->relative),
    };
}

sub options {
    return qw(
        dest-dir|dir=s
        all|a!
        from=s
        to=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params;

    if (my $dir = $opt->{dest_dir} || $config->get(key => 'bundle.dest_dir') ) {
        $params{dest_dir} = dir $dir;
    }

    # Make sure we get the --all, --from and --to options passed through.
    for my $key (qw(all from to)) {
        $params{$key} = $opt->{$key} if exists $opt->{$key};
    }

    return \%params;
}

sub execute {
    my $self = shift;
    my ($targets, $changes) = $self->parse_args(
        all        => $self->all,
        args       => \@_,
        no_default => 1,
    );

    # Warn if --to or --from is specified for more thane one target.
    if ( @{ $targets } > 1 && ($self->from || $self->to) ) {
        $self->sqitch->warn(__(
            "Use of --to or --from to bundle multiple targets is not recommended.\nPass them as arguments after each target argument, instead."
        ));
    }

    # Die if --to or --from and changes are specified.
    if ( @{ $changes } && ($self->from || $self->to) ) {
        hurl bundle => __(
            'Cannot specify both --from or --to and change arguments'
        );
    }

    # Time to get started!
    $self->info(__x 'Bundling into {dir}', dir => $self->dest_dir );
    $self->bundle_config;

    if (my @fromto = grep { $_ } $self->from, $self->to) {
        # One set of from/to options for all targets.
        for my $target (@{ $targets }) {
            $self->bundle_plan($target, @fromto);
            $self->bundle_scripts($target, @fromto);
        }
    } else {
        # Separate from/to options for all targets.
        for my $target (@{ $ targets }) {
            my @fromto = splice @{ $changes }, 0, 2;
            $self->bundle_plan($target, @fromto);
            $self->bundle_scripts($target, @fromto);
        }
    }

    return $self;
}

sub _mkpath {
    my ( $self, $dir ) = @_;
    $self->debug( '    ', __x 'Created {file}', file => $dir )
        if make_path $dir, { error => \my $err };

    my $diag = shift @{ $err } or return $self;

    my ( $path, $msg ) = %{ $diag };
    hurl bundle => __x(
        'Error creating {path}: {error}',
        path  => $path,
        error => $msg,
    ) if $path;
    hurl bundle => $msg;
}

sub _copy_if_modified {
    my ( $self, $src, $dst ) = @_;

    hurl bundle => __x(
        'Cannot copy {file}: does not exist',
        file => $src,
    ) unless -e $src;

    if (-e $dst) {
        # Skip the file if it is up-to-date.
        return $self if -M $dst <= -M $src;
    } else {
        # Create the directory.
        $self->_mkpath( $dst->dir );
    }

    $self->debug('    ', __x(
        "Copying {source} -> {dest}",
        source => $src,
        dest   => $dst
    ));

    # Stringify to work around bug in File::Copy warning on 5.10.0.
    File::Copy::copy "$src", "$dst" or hurl bundle => __x(
        'Cannot copy "{source}" to "{dest}": {error}',
        source => $src,
        dest   => $dst,
        error  => $!,
    );
    return $self;
}

sub bundle_config {
    my $self = shift;
    $self->info(__ 'Writing config');
    my $file = $self->sqitch->config->local_file;
    $self->_copy_if_modified( $file, $self->dest_dir->file( $file->basename ) );
}

sub bundle_plan {
    my ($self, $target, $from, $to) = @_;

    my $dir = $self->dest_top_dir($target);

    if (!defined $from && !defined $to) {
        $self->info(__ 'Writing plan');
        my $file = $target->plan_file;
        return $self->_copy_if_modified(
            $file,
            $dir->file( $file->basename ),
        );
    }

    $self->info(__x(
        'Writing plan from {from} to {to}',
        from => $from // '@ROOT',
        to   => $to   // '@HEAD',
    ));

    $self->_mkpath( $dir );
    $target->plan->write_to(
        $dir->file( $target->plan_file->basename ),
        $from,
        $to,
    );
}

sub bundle_scripts {
    my ($self, $target, $from, $to) = @_;
    my $plan = $target->plan;

    my $from_index = $plan->index_of(
        $from // '@ROOT'
    ) // hurl bundle => __x(
        'Cannot find change {change}',
        change => $from,
    );

    my $to_index = $plan->index_of(
        $to // '@HEAD'
    ) // hurl bundle => __x(
        'Cannot find change {change}',
        change => $to,
    );

    $self->info(__ 'Writing scripts');
    $plan->position( $from_index );
    my $dir_for = $self->dest_dirs_for($target);

    while ( $plan->position <= $to_index ) {
        my $change = $plan->current // last;
        $self->info('  + ', $change->format_name_with_tags);
        my $prefix = $change->is_reworked ? 'reworked_' : '';
        my @path = $change->path_segments;
        if (-e ( my $file = $change->deploy_file )) {
            $self->_copy_if_modified(
                $file,
                $dir_for->{"${prefix}deploy"}->file(@path)
            );
        }
        if (-e ( my $file = $change->revert_file )) {
            $self->_copy_if_modified(
                $file,
                $dir_for->{"${prefix}revert"}->file(@path)
            );
        }
        if (-e ( my $file = $change->verify_file )) {
            $self->_copy_if_modified(
                $file,
                $dir_for->{"${prefix}verify"}->file(@path)
            );
        }
        $plan->next;
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::bundle - Bundle Sqitch changes for distribution

=head1 Synopsis

  my $cmd = App::Sqitch::Command::bundle->new(%params);
  $cmd->execute;

=head1 Description

Bundles a Sqitch project for distribution. Done by creating a new directory
and copying the configuration file, plan file, and change files into it.

=head1 Interface

=head2 Attributes

=head3 C<from>

Change from which to build the bundled plan.

=head3 C<to>

Change up to which to build the bundled plan.

=head3 C<all>

Boolean indicating whether or not to run the command against all plans in the
project.

=head2 Instance Methods

=head3 C<execute>

  $bundle->execute($command);

Executes the C<bundle> command.

=head3 C<bundle_config>

 $bundle->bundle_config;

Copies the configuration file to the bundle directory.

=head3 C<bundle_plan>

 $bundle->bundle_plan($target);

Copies the plan file for the specified target to the bundle directory.

=head3 C<bundle_scripts>

 $bundle->bundle_scripts($target);

Copies the deploy, revert, and verify scripts for each step in the plan for
the specified target to the bundle directory. Files in the script directories
that do not correspond to changes in the plan will not be copied.

=head3 C<dest_top_dir>

  my $top_dir = $bundle->top_dir($target);

Returns the destination top directory for the specified target.

=head3 C<dest_dirs_for>

  my $dirs = $bundle->dest__dirs_for($target);

Returns a hash of change script destination directories for the specified
target. The keys are the types of scripts, and include:

=over

=item C<deploy>

=item C<revert>

=item C<verfiy>

=item C<reworked_deploy>

=item C<reworked_revert>

=item C<reworked_verfiy>

=back

=head1 See Also

=over

=item L<sqitch-bundle>

Documentation for the C<bundle> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2018 iovation Inc.

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
