package App::Sqitch::Plan::Change;

use 5.010;
use utf8;
use namespace::autoclean;
use parent 'App::Sqitch::Plan::Line';
use Encode;
use Mouse;
use App::Sqitch::DateTime;
use App::Sqitch::Plan::Depend;
use Locale::TextDomain qw(App-Sqitch);

our $VERSION = '0.970';

has _requires => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Depend]',
    traits   => ['Array'],
    required => 1,
    init_arg => 'requires',
    default  => sub { [] },
    handles  => { requires => 'elements' },
);

has _conflicts => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Depend]',
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
    default  => ' ',
);

has since_tag => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::Tag',
    required => 0,
);

has parent => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::Change',
    required => 0,
);

has _rework_tags => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Tag]',
    traits   => ['Array'],
    required => 1,
    init_arg => 'rework_tags',
    traits   => ['Array'],
    lazy     => 1,
    default  => sub { [] },
    handles  => {
        rework_tags       => 'elements',
        add_rework_tags   => 'push',
        clear_rework_tags => 'clear',
    },
);

sub is_reworked { @{ shift->_rework_tags } > 0 }

after add_rework_tags => sub {
    my $self = shift;
    # Need to reset the file name if a new value is passed.
    $self->meta->get_attribute('_path_segments')->clear_value($self);
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

has _path_segments => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    traits   => ['Array'],
    required => 1,
    lazy     => 1,
    handles  => { path_segments => 'elements' },
    default  => sub {
        my $self = shift;
        my @path = split m{/} => $self->name;
        my $ext  = '.' . $self->sqitch->extension;
        if (my @rework_tags = $self->rework_tags) {
            # Determine suffix based on the first one found in the deploy dir.
            my $dir = $self->sqitch->deploy_dir;
            my $bn  = pop @path;
            my $first;
            for my $tag (@rework_tags) {
                my $fn = join '', $bn, $tag->format_name, $ext;
                $first //= $fn;
                if ( -e $dir->file(@path, $fn) ) {
                    push @path => $fn;
                    $first = undef;
                    last;
                }
            }
            push @path => $first if defined $first;
        } else {
            $path[-1] .= $ext;
        }
        return \@path;
    },
);

has info => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $reqs  = join "\n  + ", map { $_->as_string } $self->requires;
        my $confs = join "\n  - ", map { $_->as_string } $self->conflicts;
        return join "\n", (
            'project ' . $self->project,
            ( $self->uri ? ( 'uri ' . $self->uri->canonical ) : () ),
            'change '  . $self->format_name,
            ( $self->parent ? ( 'parent ' . $self->parent->id ) : () ),
            'planner ' . $self->format_planner,
            'date '    . $self->timestamp->as_string,
            ( $reqs  ? "requires\n  + $reqs" : ()),
            ( $confs ? "conflicts\n  - $confs" : ()),
            ( $self->note ? ('', $self->note) : ()),
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

has old_info => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        return join "\n", (
            'project ' . $self->project,
            ( $self->uri ? ( 'uri ' . $self->uri->canonical ) : () ),
            'change '  . $self->format_name,
            'planner ' . $self->format_planner,
            'date '    . $self->timestamp->as_string,
        );
    }
);

has old_id => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $content = encode_utf8 shift->old_info;
        require Digest::SHA1;
        return Digest::SHA1->new->add(
            'change ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

has timestamp => (
    is       => 'ro',
    isa      => 'App::Sqitch::DateTime',
    required => 1,
    default  => sub { App::Sqitch::DateTime->now },
);

has planner_name => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    default  => sub { shift->sqitch->user_name },
);

has planner_email => (
    is       => 'ro',
    isa      => 'UserEmail',
    required => 1,
    default  => sub { shift->sqitch->user_email },
);

sub dependencies {
    my $self = shift;
    return $self->requires, $self->conflicts;
}

sub deploy_file {
    my $self   = shift;
    $self->sqitch->deploy_dir->file( $self->path_segments );
}

sub revert_file {
    my $self   = shift;
    $self->sqitch->revert_dir->file( $self->path_segments );
}

sub verify_file {
    my $self   = shift;
    $self->sqitch->verify_dir->file( $self->path_segments );
}

sub script_file {
    my ($self, $name) = @_;
    if ( my $meth = $self->can("$name\_file") ) {
        return $self->$meth;
    }
    return $self->sqitch->top_dir->subdir($name)->cleanup->file(
        $self->path_segments
    );
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

sub format_dependencies {
    my $self = shift;
    my $deps = join(
        ' ',
        map { $_->as_plan_string } $self->requires, $self->conflicts
    ) or return '';
    return "[$deps]";
}

sub format_name_with_dependencies {
    my $self = shift;
    my $dep = $self->format_dependencies or return $self->format_name;
    return $self->format_name . $self->pspace . $dep;
}

sub format_op_name_dependencies {
    my $self = shift;
    return $self->format_operator . $self->format_name_with_dependencies;
}

sub format_planner {
    my $self = shift;
    return join ' ', $self->planner_name, '<' . $self->planner_email . '>';
}

sub deploy_handle {
    my $self = shift;
    $self->plan->open_script($self->deploy_file);
}

sub revert_handle {
    my $self = shift;
    $self->plan->open_script($self->revert_file);
}

sub verify_handle {
    my $self = shift;
    $self->plan->open_script($self->verify_file);
}

sub format_content {
    my $self = shift;
    return $self->SUPER::format_content . $self->pspace . join (
        ' ',
        ($self->format_dependencies || ()),
        $self->timestamp->as_string,
        $self->format_planner
    );
}

sub requires_changes {
    my $self = shift;
    my $plan = $self->plan;
    return map { $plan->find( $_->key_name ) } $self->requires;
}

sub conflicts_changes {
    my $self = shift;
    my $plan = $self->plan;
    return map { $plan->find( $_->key_name ) } $self->conflicts;
}

sub note_prompt {
    my ( $self, %p ) = @_;

    return join(
        '',
        __x(
            "Please enter a note for your change. Lines starting with '#' will\n" .
            "be ignored, and an empty message aborts the {command}.",
            command => $p{for},
        ),
        "\n",
        __x('Change to {command}:', command => $p{for}),
        "\n\n",
        '  ', $self->format_op_name_dependencies,
        join "\n    ", '', @{ $p{scripts} },
        "\n",
    );
}

__PACKAGE__->meta->make_immutable;
no Mouse;

__END__

=head1 Name

App::Sqitch::Plan::Change - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

A App::Sqitch::Plan::Change represents a change as parsed from a plan file. In
addition to the interface inherited from L<App::Sqitch::Plan::Line>, it offers
interfaces for parsing dependencies from the deploy script, as well as for
opening the deploy, revert, and verify scripts.

=head1 Interface

See L<App::Sqitch::Plan::Line> for the basics.

=head2 Accessors

=head3 C<since_tag>

An L<App::Sqitch::Plan::Tag> object representing the last tag to appear in the
plan B<before> the change. May be C<undef>.

=head3 C<pspace>

Blank space separating the change name from the dependencies, timestamp, and
planner in the file.

=head3 C<is_reworked>

Boolean indicting whether or not the change has been reworked.

=head3 C<info>

Information about the change, returned as a string. Includes the change ID,
the name and email address of the user who added the change to the plan, and
the timestamp for when the change was added to the plan.

=head3 C<id>

A SHA1 hash of the data returned by C<info()>, which can be used as a
globally-unique identifier for the change.

=head3 C<timestamp>

Returns the an L<App::Sqitch::DateTime> object representing the time at which
the change was added to the plan.

=head3 C<planner_name>

Returns the name of the user who added the change to the plan.

=head3 C<planner_email>

Returns the email address of the user who added the change to the plan.

=head2 Instance Methods

=head3 C<path_segments>

  my @segments = $change->path_segments;

Returns the path segment for the change. For example, if the change is named
"foo", C<('foo.sql')> is returned. If the change is named "functions/bar>
C<('functions', 'bar.sql')> is returned. Internally, this data is used to
create the deploy, revert, and verify file names.

=head3 C<deploy_file>

  my $file = $change->deploy_file;

Returns the path to the deploy script file for the change.

=head3 C<revert_file>

  my $file = $change->revert_file;

Returns the path to the revert script file for the change.

=head3 C<verify_file>

  my $file = $change->verify_file;

Returns the path to the verify script file for the change.

=head3 C<script_file>

  my $file = $sqitch->script_file($script_name);

Returns the path to a script, for the change.

=head3 C<rework_tags>

  my @tags = $change->rework_tags;

Returns a list of tags that occur between a change and its next reworking.
Returns an empty list if the change is not reworked.

=head3 C<add_rework_tags>

  $change->add_rework_tags(@tags);

Add to the list of rework tags.

=head3 C<requires>

  my @requires = $change->requires;

Returns a list of L<App::Sqitch::Plan::Depend> objects representing changes
required by this change.

=head3 C<requires_changes>

  my @requires_changes = $change->requires_changes;

Returns a list of the C<App::Sqitch::Plan::Change> objects representing
changes required by this change.

=head3 C<conflicts>

  my @conflicts = $change->conflicts;

Returns a list of L<App::Sqitch::Plan::Depend> objects representing changes
with which this change conflicts.

=head3 C<conflicts_changes>

  my @conflicts_changes = $change->conflicts_changes;

Returns a list of the C<App::Sqitch::Plan::Change> objects representing
changes with which this change conflicts.

=head3 C<dependencies>

  my @dependencies = $change->dependencies;

Returns a list of L<App::Sqitch::Plan::Depend> objects representing all
dependencies, required and conflicting.

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

=head3 C<format_dependencies>

  my $dependencies = $change->format_dependencies;

Returns a string containing a bracketed list of dependencies. If there are no
dependencies, an empty string will be returned.

=head3 C<format_name_with_dependencies>

  my $name_with_dependencies = $change->format_name_with_dependencies;

Returns a string formatted with the change name followed by a bracketed list
of dependencies, if any, associated with the change. Used to display a change
when added to a plan.

=head3 C<format_op_name_dependencies>

  my $op_name_dependencies = $change->format_op_name_dependencies;

Like C<format_name_with_dependencies>, but includes the operator, if present.

=head3 C<format_planner>

  my $planner = $change->format_planner;

Returns a string formatted with the name and email address of the user who
added the change to the plan.

=head3 C<deploy_handle>

  my $fh = $change->deploy_handle;

Returns an L<IO::File> file handle, opened for reading, for the deploy script
for the change.

=head3 C<revert_handle>

  my $fh = $change->revert_handle;

Returns an L<IO::File> file handle, opened for reading, for the revert script
for the change.

=head3 C<verify_handle>

  my $fh = $change->verify_handle;

Returns an L<IO::File> file handle, opened for reading, for the verify script
for the change.

=head3 C<note_prompt>

  my $prompt = $change->note_prompt(
      for     => 'rework',
      scripts => [$change->deploy_file, $change->revert_file],
  );

Overrides the implementation from C<App::Sqitch::Plan::Line> to add the
C<files> parameter. This is a list of the files to be created for the command.
These will usually be the deploy, revert, and verify files, but the caller
might not be creating all of them, so it needs to pass the list.

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

Copyright (c) 2012-2014 iovation Inc.

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
