package App::Sqitch::Plan::Depend;

use v5.10.1;
use utf8;
use Moose;
use App::Sqitch::Plan;
use App::Sqitch::X qw(hurl);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

has conflicts => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has project => (
    is  => 'ro',
    isa => 'Maybe[Str]',
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
        return undef if $self->project ne $plan->project;
        my $change = $plan->find( $self->key_name ) // hurl plan => __x(
            'Unable to find change "{change}" in plan {file}',
            change => $self->key_name,
            file   => $plan->sqitch->plan_file,
        );
        return $change->id;
    }
);

sub required { shift->conflicts ? 0 : 1 }

sub BUILD {
    my $self = shift;
    hurl 'Depend object must have either "change" or "tag" defined (or both)'
        unless defined $self->change || defined $self->tag;
}

sub parse {
    my ( $class, $string ) = @_;
    my $name_re = App::Sqitch::Plan->name_regex;
    return undef if $string !~ /
        \A                            # Beginning of string
        (?<conflicts>!?)              # Optional negation
        (?:(?<project>$name_re)[:])?  # Optional project + :
        (?:                           # Followed by...
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

    return join '' => @parts;
}

sub as_string {
    my $self = shift;
    my $proj = $self->project;
    return $self->key_name if $proj eq $self->plan->project;
    return "$proj:" . $self->key_name;
}


sub as_plan_string {
    my $self = shift;
    return ($self->conflicts ? '!' : '') . $self->as_string;
}

__PACKAGE__->meta->make_immutable;
no Moose;

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

=back

=head3 C<parse>

  my %params = App::Sqitch::Plan::Depend->parse($string);

parses a dependency specification as extracted from a plan and returns a hash
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

=head3 C<project>

  my $proj = $depend->project;

Returns the name of the project with which the dependency is associated.

=head3 C<change>

  my $change = $depend->change;

Returns the name of the change, if any. If C<undef> is returned, the dependency
is a tag-only dependency.

=head3 C<tag>

  my $tag = $depend->tag;

Returns the name of the tag, if any. If C<undef> is returned, the dependency
is a change-only dependency.

=head2 Instance Methods

=head3 C<key_name>

Returns the key name of the depenedency, with the change name and/or tag,
properly formatted for passing to the C<find()> method of
L<App::Sqitch::Plan>.

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
