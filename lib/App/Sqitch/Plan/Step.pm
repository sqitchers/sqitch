package App::Sqitch::Plan::Step;

use v5.10.1;
use utf8;
use namespace::autoclean;
use parent 'App::Sqitch::Plan::Line';
use Encode;
use Moose;

has _dependencies => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    builder  => '_parse_dependencies',
);

has since_tag => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::Tag',
    required => 0,
);

has _tags => (
    is         => 'ro',
    traits  => ['Array'],
    isa        => 'ArrayRef[App::Sqitch::Plan::Tag]',
    lazy       => 1,
    required   => 1,
    default    => sub { [] },
    handles => {
        tags    => 'elements',
        add_tag => 'push',
    },
);

has deploy_file => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->plan->sqitch;
        $sqitch->deploy_dir->file( $self->name . '.' . $sqitch->extension );
    }
);

has revert_file => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->plan->sqitch;
        $sqitch->revert_dir->file( $self->name . '.' . $sqitch->extension );
    }
);

has test_file => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->plan->sqitch;
        $sqitch->test_dir->file( $self->name . '.' . $sqitch->extension );
    }
);

has info => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;

        my @since;
        if (my $tag = $self->since_tag) {
            @since = ('since ' . $tag->id);
        }

        return join "\n", (
            'project ' . $self->plan->sqitch->uri->canonical,
            'step '    . $self->format_name,
            @since,
        );
    }
);

has id => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $content = encode_utf8 shift->info;
        require Digest::SHA1;
        return Digest::SHA1->new->add(
            'step ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

sub is_revert {
    shift->operator eq '-';
}

sub is_deploy {
    shift->operator ne '-';
}

sub action {
    shift->is_deploy ? 'deploy' : 'revert';
}

sub format_name_with_tags {
    my $self = shift;
    return join ' ', $self->format_name, map { $_->format_name } $self->tags;
}

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    if ($p->{requires} && $p->{conflicts} ) {
        $p->{_dependencies} = {
            requires  => delete $p->{requires},
            conflicts => delete $p->{conflicts},
        };
    } elsif ($p->{conflicts} || $p->{requires}) {
        require Carp;
        Carp::confess(
            'The "conflicts" and "requires" parameters must both be required',
            ' or omitted'
        );
    }
    return $p;
}

sub deploy_handle {
    my $self = shift;
    $self->plan->open_script($self->deploy_file);
}

sub revert_handle {
    my $self = shift;
    $self->plan->open_script($self->revert_file);
}

sub test_handle {
    my $self = shift;
    $self->plan->open_script($self->test_file);
}

sub requires  { @{ shift->_dependencies->{requires}  } }
sub conflicts { @{ shift->_dependencies->{conflicts} } }

sub _parse_dependencies {
    my $self = shift;
    my $fh   = $self->plan->open_script( $self->deploy_file );

    my $comment = qr{#+|--+|/[*]+|;+};
    my %deps = ( requires => [], conflicts => [] );
    while ( my $line = $fh->getline ) {
        chomp $line;
        last if $line =~ /\A\s*$/;           # Blank line, no more headers.
        last if $line !~ /\A\s*$comment/;    # Must be a comment line.
        my ( $label, $value ) =
            $line =~ /$comment\s*:(requires|conflicts):\s*(.+)/;
        push @{ $deps{$label} ||= [] } => split /\s+/ => $value
            if $label && $value;
    }
    return \%deps;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Step - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

A App::Sqitch::Plan::Step represents deployment step as parsed from a plan
file. In addition to the interface inherited from L<App::Sqitch::Plan::Line>,
it offers interfaces for parsing dependencies from the deploy script, as well
as for opening the deploy, revert, and test scripts.

=head1 Interface

See L<App::Sqitch::Plan::Line> for the basics.

=head2 Accessors

=head3 C<since_tag>

An L<App::Sqitch::Plan::Tag> object representing the last tag to appear in the
plan B<before> the step. May be C<undef>.

=head3 C<deploy_file>

  my $file = $step->deploy_file;

Returns the path to the deploy script file for the step.

=head3 C<revert_file>

  my $file = $step->revert_file;

Returns the path to the revert script file for the step.

=head3 C<test_file>

  my $file = $step->test_file;

Returns the path to the test script file for the step.

=head2 Instance Methods

=head3 C<requires>

  my @requires = $step->requires;

Returns a list of the names of steps required by this step.

=head3 C<conflicts>

  my @conflicts = $step->conflicts;

Returns a list of the names of steps with which this step conflicts.

=head3 C<is_deploy>

Returns true if the step is intended to be deployed, and false if it should be
reverted.

=head3 C<is_revert>

Returns true if the step is intended to be reverted, and false if it should be
deployed.

=head3 C<action>

Returns "deploy" if the step should be deployed, or "revert" if it should be
reverted.

=head3 C<format_name_with_tags>

  my $name_with_tags = $step->format_name_with_tags;

Returns a string formatted with the step name followed by the list of tags, if
any, associated with the step. Used to display a step as it is deployed.

=head3 C<deploy_handle>

  my $fh = $step->deploy_handle;

Returns an L<IO::File> file handle, opened for reading, for the deploy script
for the step.

=head3 C<revert_handle>

  my $fh = $step->revert_handle;

Returns an L<IO::File> file handle, opened for reading, for the revert script
for the step.

=head3 C<test_handle>

  my $fh = $step->test_handle;

Returns an L<IO::File> file handle, opened for reading, for the test script
for the step.

=head1 See Also

=over

=item L<App::Sqitch::Plan>

Class representing a plan.

=item L<App::Sqitch::Plan::Line>

Base class from which App::Sqitch::Plan::Step inherits.

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
