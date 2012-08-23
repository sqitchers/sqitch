package App::Sqitch::Command::bundle;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Moose;
use MooseX::Types::Path::Class;
use Path::Class;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.912';

has dest_dir => (
    is       => 'ro',
    isa      => 'Path::Class::Dir',
    required => 1,
    default  => sub { dir 'bundle' },
);

has _dir_map => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $sqitch = $self->sqitch;
        my $dst    = $self->dest_dir;
        my $ret    = {};

        for my $attr (qw(deploy_dir revert_dir test_dir)) {
            my $dir = $sqitch->$attr;
            # Map source to test if source exists and has children.
            $ret->{$attr} = [ $dir, dir $dst, $dir->relative ]
                if -e $dir && scalar $dir->children;
        }

        return $ret;
    },
);

sub options {
    return qw(
        dest_dir|dir=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params;

    if (my $dir = $opt->{dest_dir} || $config->get(key => 'bundle.dest_dir') ) {
        $params{dest_dir} = dir $dir;
    }

    return \%params;
}

sub execute {
    my $self = shift;

    return $self;
}

sub make_directories {
    my $self   = shift;
    my $dirs   = $self->_dir_map;

    for my $dir (qw(deploy_dir revert_dir test_dir)) {
        my ( $src, $dst ) = @{ $dirs->{$dir} || [] } or next;
        $self->info( __ 'Created {file}', file => $dst )
            if make_path $dst, { error => \my $err };
        if ( my $diag = shift @{ $err } ) {
            my ( $path, $msg ) = %{ $diag };
            hurl init => __x(
                'Error creating {path}: {error}',
                path  => $path,
                error => $msg,
            ) if $path;
            hurl bundle => $msg;
        }
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

Copyright (c) 2012 iovation Inc.

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
