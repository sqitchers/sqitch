package App::Sqitch::Command::bundle;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(Str Dir Maybe);
use File::Path qw(make_path);
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Copy ();
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.999_1';

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

sub dest_top_dir {
    my $self = shift;
    dir $self->dest_dir, shift->top_dir->relative;
}

sub dest_deploy_dir {
    my $self = shift;
    dir $self->dest_dir, shift->deploy_dir->relative;
}

sub dest_revert_dir {
    my $self = shift;
    dir $self->dest_dir, shift->revert_dir->relative;
}

sub dest_verify_dir {
    my $self = shift;
    dir $self->dest_dir, shift->verify_dir->relative;
}

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

sub _targets {
    my $self = shift;
    my %args = $self->parse_args(args => shift, no_default => 1);
    my $sqitch = $self->sqitch;

    # Die on unknowns and changes.
    if (my @others = (@{ $args{unknown} }, @{ $args{changes} }) ) {
        # Well, see if they're not actually engine names or plan files.
        my %engines = map { $_ => 1 } App::Sqitch::Command::ENGINES;
        my $config = $sqitch->config;
        my %target_for = map {
            $_->plan_file => $_
        } App::Sqitch::Target->all_targets(sqitch => $sqitch);
        my @unknown;
        for my $arg (@others) {
            if ($engines{$arg}) {
                # It's an engine. Add its target.
                my $name = $config->get(key => "engine.$arg.target") || "db:$arg:";
                unless (first { $_->name eq $name }) {
                    push @{ $args{targets} } => App::Sqitch::Target->new(
                        sqitch => $sqitch,
                        name   => $name,
                    );
                }
            } elsif (my $target = $target_for{$arg}) {
                # Ah, seems to be a plan file.
                push @{ $args{targets} } => $target unless first {
                    $_->name eq $target->name
                } @{ $args{targets} };
            } else {
                # It really is unknown.
                push @unknown => $arg;
            }
        }

        # Just die on any unknowns.
        hurl bundle => __nx(
            'Unknown argument "{arg}"',
            'Unknown arguments: {arg}',
            scalar @unknown,
            arg => join ', ', @unknown
        ) if @unknown;
    }

    # Return targets if we've got them.
    return @{ $args{targets} } if @{ $args{targets} };

    # Return the default target if --engine was passed.
    return $self->default_target if $sqitch->options->{engine};

    # Return all configured targets.
    return App::Sqitch::Target->all_targets( sqitch => $sqitch );
}

sub execute {
    my $self = shift;
    $self->info(__x 'Bundling into {dir}', dir => $self->dest_dir );
    $self->bundle_config;

    my %seen;
    for my $target( $self->_targets(\@_) ) {
        next if $seen{$target->plan_file}++;
        $self->bundle_plan($target);
        $self->bundle_scripts($target);
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
    my ($self, $target) = @_;

    my $dir = $self->dest_top_dir($target);

    if (!defined $self->from && !defined $self->to) {
        $self->info(__ 'Writing plan');
        my $file = $target->plan_file;
        return $self->_copy_if_modified(
            $file,
            $dir->file( $file->basename ),
        );
    }

    $self->info(__x(
        'Writing plan from {from} to {to}',
        from => $self->from // '@ROOT',
        to   => $self->to   // '@HEAD',
    ));

    $target->plan->write_to(
        $dir->file( $target->plan_file->basename ),
        $self->from,
        $self->to,
    );
}

sub bundle_scripts {
    my ($self, $target) = @_;
    my $plan = $target->plan;

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
                $self->dest_deploy_dir($target)->file( $change->path_segments )
            );
        }
        if (-e ( my $file = $change->revert_file )) {
            $self->_copy_if_modified(
                $file,
                $self->dest_revert_dir($target)->file( $change->path_segments )
            );
        }
        if (-e ( my $file = $change->verify_file )) {
            $self->_copy_if_modified(
                $file,
                $self->dest_verify_dir($target)->file( $change->path_segments )
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
