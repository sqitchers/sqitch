package App::Sqitch::Plan::Change;

use v5.10.1;
use utf8;
use namespace::autoclean;
use parent 'App::Sqitch::Plan::Line';
use Encode;
use Moose;

has _requires => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    traits   => ['Array'],
    required => 1,
    init_arg => 'requires',
    default  => sub { [] },
    handles  => { requires => 'elements' },
);

has _conflicts => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    traits   => ['Array'],
    required => 1,
    init_arg => 'conflicts',
    default  => sub { [] },
    handles  => { conflicts => 'elements' },
);

has pspace => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => '',
);

has since_tag => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::Tag',
    required => 0,
);

has suffix => (
    is       => 'rw',
    isa      => 'Str',
    required => 1,
    default  => '',
);

after suffix => sub {
    my $self = shift;
    # Need to reset the file name if a new value is passed.
    $self->meta->get_attribute('_fn')->clear_value($self) if @_;
};

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

has _fn => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my @path = split m{/} => $self->name;
        $path[-1] = join '', (
            $path[-1],
            $self->suffix,
            '.',
            $self->sqitch->extension,
        );
        return \@path;
    },
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
            'project ' . $self->sqitch->uri->canonical,
            'change '    . $self->format_name,
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
            'change ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

sub deploy_file {
    my $self   = shift;
    $self->sqitch->deploy_dir->file( @{ $self->_fn } );
}

sub revert_file {
    my $self   = shift;
    $self->sqitch->revert_dir->file( @{ $self->_fn } );
}

sub test_file {
    my $self   = shift;
    $self->sqitch->test_dir->file( @{ $self->_fn } );
}

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

sub format_content {
    my $self = shift;
    return $self->SUPER::format_content . $self->pspace . join (
        ' ',
        ( map { ":$_" } $self->requires  ),
        ( map { "!$_" } $self->conflicts ),
    );
}

sub requires_changes {
    my $self = shift;
    my $plan = $self->plan;
    return map { $plan->find($_) } $self->requires;
}

sub conflicts_changes {
    my $self = shift;
    my $plan = $self->plan;
    return map { $plan->find($_) } $self->conflicts;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Change - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

A App::Sqitch::Plan::Change represents deployment change as parsed from a plan
file. In addition to the interface inherited from L<App::Sqitch::Plan::Line>,
it offers interfaces for parsing dependencies from the deploy script, as well
as for opening the deploy, revert, and test scripts.

=head1 Interface

See L<App::Sqitch::Plan::Line> for the basics.

=head2 Accessors

=head3 C<since_tag>

An L<App::Sqitch::Plan::Tag> object representing the last tag to appear in the
plan B<before> the change. May be C<undef>.

=head2 Instance Methods

=head3 C<deploy_file>

  my $file = $change->deploy_file;

Returns the path to the deploy script file for the change.

=head3 C<revert_file>

  my $file = $change->revert_file;

Returns the path to the revert script file for the change.

=head3 C<test_file>

  my $file = $change->test_file;

Returns the path to the test script file for the change.

=head3 C<requires>

  my @requires = $change->requires;

Returns a list of the names of changes required by this change.

=head3 C<requires_changes>

  my @requires_changes = $change->requires_changes;

Returns a list of the changes required by this change.

=head3 C<conflicts>

  my @conflicts = $change->conflicts;

Returns a list of the names of changes with which this change conflicts.

=head3 C<conflicts_changes>

  my @conflicts_changes = $change->conflicts_changes;

Returns a list of the changes with which this change conflicts.

=head3 C<is_deploy>

Returns true if the change is intended to be deployed, and false if it should be
reverted.

=head3 C<is_revert>

Returns true if the change is intended to be reverted, and false if it should be
deployed.

=head3 C<action>

Returns "deploy" if the change should be deployed, or "revert" if it should be
reverted.

=head3 C<format_name_with_tags>

  my $name_with_tags = $change->format_name_with_tags;

Returns a string formatted with the change name followed by the list of tags, if
any, associated with the change. Used to display a change as it is deployed.

=head3 C<deploy_handle>

  my $fh = $change->deploy_handle;

Returns an L<IO::File> file handle, opened for reading, for the deploy script
for the change.

=head3 C<revert_handle>

  my $fh = $change->revert_handle;

Returns an L<IO::File> file handle, opened for reading, for the revert script
for the change.

=head3 C<test_handle>

  my $fh = $change->test_handle;

Returns an L<IO::File> file handle, opened for reading, for the test script
for the change.

=head1 See Also

=over

=item L<App::Sqitch::Plan>

Class representing a plan.

=item L<App::Sqitch::Plan::Line>

Base class from which App::Sqitch::Plan::Change inherits.

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
