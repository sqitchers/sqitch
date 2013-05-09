package App::Sqitch::Plan::Depend;

use 5.010;
use utf8;
use Mouse;
use App::Sqitch::Plan;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

our $VERSION = '0.971';

has conflicts => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has got_id => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1
);

has got_project => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1
);

has project => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;

        # Local project is the default unless an ID was passed.
        return $plan->project unless $self->got_id;

        # Local project is default if passed ID is in plan.
        return $plan->project if $plan->find( $self->id );

        # Otherwise, the project is unknown (and external).
        return undef;
    }
);

has change => (
    is  => 'ro',
    isa => 'Maybe[Str]',
);

has tag => (
    is  => 'ro',
    isa => 'Maybe[Str]',
);

has plan => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan',
    weak_ref => 1,
    required => 1,
);

has id => (
    is       => 'ro',
    isa      => 'Maybe[Str]',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;
        my $proj = $self->project // return undef;
        return undef if $proj ne $plan->project;
        my $change = $plan->find( $self->key_name ) // hurl plan => __x(
            'Unable to find change "{change}" in plan {file}',
            change => $self->key_name,
            file   => $plan->sqitch->plan_file,
        );
        return $change->id;
    }
);

has resolved_id => (
    is  => 'rw',
    isa => 'Maybe[Str]',
);

has is_external => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;

        # If no project, then it must be external.
        my $proj = $self->project // return 1;

        # Just compare to the local project.
        return $proj eq $self->plan->project ? 0 : 1;
    },
);

sub type        { shift->conflicts   ? 'conflict' : 'require' }
sub required    { shift->conflicts   ? 0 : 1 }
sub is_internal { shift->is_external ? 0 : 1 }

sub BUILDARGS {
    my $class = shift;
    my $p = @_ == 1 && ref $_[0] ? { %{ +shift } } : { @_ };
    hurl 'Depend object must have either "change", "tag", or "id" defined'
        unless length($p->{change} // '') || length($p->{tag} // '') || $p->{id};

    hurl 'Depend object cannot contain both an ID and a tag or change'
        if $p->{id} && (length($p->{change} // '') || length($p->{tag} // ''));

    $p->{got_id}      = defined $p->{id}      ? 1 : 0;
    $p->{got_project} = defined $p->{project} ? 1 : 0;

    return $p;
}

sub parse {
    my ( $class, $string ) = @_;
    my $name_re = App::Sqitch::Plan->name_regex;
    return undef if $string !~ /
        \A                            # Beginning of string
        (?<conflicts>!?)              # Optional negation
        (?:(?<project>$name_re)[:])?  # Optional project + :
        (?:                           # Followed by...
            (?<id>[0-9a-f]{40})       #     SHA1 hash
        |                             # - OR -
            (?<change>$name_re)       #     Change name
            (?:[@](?<tag>$name_re))?  #     Optional tag
        |                             # - OR -
            (?:[@](?<tag>$name_re))?  #     Tag
        )                             # ... required
        \z                            # End of string
    /x;

    return { %+, conflicts => $+{conflicts} ? 1 : 0 };
}

sub key_name {
    my $self = shift;
    my @parts;

    if (defined (my $change = $self->change)) {
        push @parts => $change;
    }

    if (defined (my $tag = $self->tag)) {
        push @parts => '@' . $tag;
    }

    if ( !@parts && defined ( my $id = $self->id ) ) {
        push @parts, $id;
    }

    return join '' => @parts;
}

sub as_string {
    my $self = shift;
    my $proj = $self->project // return $self->key_name;
    return $self->key_name if $proj eq $self->plan->project;
    return "$proj:" . $self->key_name;
}

sub as_plan_string {
    my $self = shift;
    return ($self->conflicts ? '!' : '') . $self->as_string;
}

__PACKAGE__->meta->make_immutable;
no Mouse;

__END__

=head1 Name

App::Sqitch::Plan::Depend - Sqitch dependency specification

=head1 Synopsis

  my $depend = App::Sqitch::Plan::Depend->new(
        plan => $plan,
        App::Sqitch::Plan::Depend->parse('!proj:change@tag')
  );

=head1 Description

An App::Sqitch::Plan::Line represents a single dependency from the dependency
list for a planned change. Is is constructed by L<App::Sqitch::Plan> and
included in L<App::Sqitch::Plan::Change> objects C<conflicts> and C<requires>
attributes.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $depend = App::Sqitch::Plan::Depend->new(%params);

Instantiates and returns a App::Sqitch::Plan::Line object. Parameters:

=over

=item C<plan>

The plan with which the dependency is associated. Required.

=item C<project>

Name of the project. Required.

=item C<conflicts>

Boolean to indicate whether the dependency is a conflicting dependency.

=item C<change>

The name of the change.

=item C<tag>

The name of the tag claimed as the dependency.

=item C<id>

The ID of a change. Mutually exclusive with C<change> and C<tag>.

=back

=head3 C<parse>

  my %params = App::Sqitch::Plan::Depend->parse($string);

Parses a dependency specification as extracted from a plan and returns a hash
reference of parameters suitable for passing to C<new()>. Returns C<undef> if
the string is not a properly-formatted dependency.

=head2 Accessors

=head3 C<plan>

  my $plan = $depend->plan;

Returns the L<App::Sqitch::Plan> object with which the dependency
specification is associated.

=head3 C<conflicts>

  say $depend->as_string, ' conflicts' if $depend->conflicts;

Returns true if the dependency is a conflicting dependency, and false if it
is not (in which case it is a required dependency).

=head3 C<required>

  say $depend->as_string, ' required' if $depend->required;

Returns true if the dependency is a required, and false if it is not (in which
case it is a conflicting dependency).

=head3 C<type>

  say $depend->type;

Returns a string indicating the type of dependency, either "require" or
"conflict".

=head3 C<project>

  my $proj = $depend->project;

Returns the name of the project with which the dependency is associated.

=head3 C<got_project>

Returns true if the C<project> parameter was passed to the constructor with a
defined value, and false if it was not passed to the constructor.

=head3 C<change>

  my $change = $depend->change;

Returns the name of the change, if any. If C<undef> is returned, the dependency
is a tag-only dependency.

=head3 C<tag>

  my $tag = $depend->tag;

Returns the name of the tag, if any. If C<undef> is returned, the dependency
is a change-only dependency.

=head3 C<id>

Returns the ID of the change if the dependency was specified as an ID, or if
the dependency is a local dependency.

=head3 C<got_id>

Returns true if the C<id> parameter was passed to the constructor with a
defined value, and false if it was not passed to the constructor.

=head3 C<resolved_id>

Change ID used by the engine when deploying a change. That is, if the
dependency is in the database, it will be assigned this ID from the database.
If it is not in the database, C<resolved_id> will be undef.

=head3 C<is_external>

Returns true if the dependency references a change external to the current
project, and false if it is part of the current project.

=head3 C<is_internal>

The opposite of C<is_external()>: returns true if the dependency is in the
internal (current) project, and false if not.

=head2 Instance Methods

=head3 C<key_name>

Returns the key name of the dependency, with the change name and/or tag,
properly formatted for passing to the C<find()> method of
L<App::Sqitch::Plan>. If the dependency was specified as an ID, rather than a
change or tag, then the ID will be returned.

=head3 C<as_string>

Returns the project-qualified key name. That is, if there is a project name,
it returns a string with the project name, a colon, and the key name. If there
is no project name, the key name is returned.

=head3 C<as_plan_string>

  my $string = $depend->as_string;

Returns the full stringification of the dependency, suitable for output to a
plan file. That is, the same as C<as_string> unless C<conflicts> returns true,
in which case it is prepended with "!".

=head1 See Also

=over

=item L<App::Sqitch::Plan>

Class representing a plan.

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
