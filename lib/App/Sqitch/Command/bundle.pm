package App::Sqitch::Command::bundle;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse;
use MouseX::Types::Path::Class;
use File::Path qw(make_path);
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Copy ();
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.981';

has from => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
);

has to => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
);

has dest_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    default  => sub { dir 'bundle' },
);

has dest_top_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    default  => sub {
        my $self = shift;
        dir $self->dest_dir, $self->sqitch->top_dir->relative;
    },
);

has dest_deploy_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        dir $self->dest_dir, $self->sqitch->deploy_dir->relative;
    },
);

has dest_revert_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        dir $self->dest_dir, $self->sqitch->revert_dir->relative;
    },
);

has dest_verify_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        dir $self->dest_dir, $self->sqitch->verify_dir->relative;
    },
);

sub options {
    return qw(
        dest-dir|dir=s
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

    # Make sure we get the --from and --to options passed through.
    for my $key (qw(from to)) {
        $params{$key} = $opt->{$key} if exists $opt->{$key};
    }

    return \%params;
}

sub execute {
    my $self = shift;
    $self->info(__x 'Bundling into {dir}', dir => $self->dest_dir );
    $self->bundle_config;
    $self->bundle_plan;
    $self->bundle_scripts;
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
    my $self   = shift;
    my $sqitch = $self->sqitch;
    if (!defined $self->from && !defined $self->to) {
        $self->info(__ 'Writing plan');
        my $file = $self->sqitch->plan_file;
        return $self->_copy_if_modified(
            $file,
            $self->dest_top_dir->file( $file->basename ),
        );
    }

    $self->info(__x(
        'Writing plan from {from} to {to}',
        from => $self->from // '@ROOT',
        to   => $self->to   // '@HEAD',
    ));

    $sqitch->plan->write_to(
        $self->dest_top_dir->file( $sqitch->plan_file->basename ),
        $self->from,
        $self->to,
    );
}

sub bundle_scripts {
    my $self = shift;
    my $top  = $self->sqitch->top_dir;
    my $plan = $self->plan;
    my $dir  = $self->dest_dir;

    my $from_index = $plan->index_of(
        $self->from // '@ROOT'
    ) // hurl bundle => __x(
        'Cannot find change {change}',
        change => $self->from,
    );

    my $to_index = $plan->index_of(
        $self->to // '@HEAD'
    ) // hurl bundle => __x(
        'Cannot find change {change}',
        change => $self->to,
    );

    $self->info(__ 'Writing scripts');
    $plan->position( $from_index );
    while ( $plan->position <= $to_index ) {
        my $change = $plan->current // last;
        $self->info('  + ', $change->format_name_with_tags);
        if (-e ( my $file = $change->deploy_file )) {
            $self->_copy_if_modified(
                $file,
                $self->dest_deploy_dir->file( $change->path_segments )
            );
        }
        if (-e ( my $file = $change->revert_file )) {
            $self->_copy_if_modified(
                $file,
                $self->dest_revert_dir->file( $change->path_segments )
            );
        }
        if (-e ( my $file = $change->verify_file )) {
            $self->_copy_if_modified(
                $file,
                $self->dest_verify_dir->file( $change->path_segments )
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

=head2 Instance Methods

=head3 C<execute>

  $bundle->execute($command);

Executes the C<bundle> command.

=head3 C<bundle_config>

 $bundle->bundle_config;

Copies the configuration file to the bundle directory.

=head3 C<bundle_plan>

 $bundle->bundle_plan;

Copies the plan file to the bundle directory.

=head3 C<bundle_scripts>

 $bundle->bundle_scripts;

Copies the deploy, revert, and verify scripts for each step in the plan to the
bundle directory. Files in the script directories that do not correspond to
changes in the plan will not be copied.

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
