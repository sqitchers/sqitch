package App::Sqitch::Plan::StepList;

use v5.10.1;
use utf8;
use strict;
use Carp;
use List::Util;

sub new {
    my $class = shift;
    my $self = bless {
        list           => [],
        lookup         => {},
        last_tagged_at => undef,
    } => $class;
    return $self->append(@_);
}

sub count     { scalar @{ shift->{list} } }
sub steps     { @{ shift->{list} } }
sub items     { @{ shift->{list} } }
sub step_at   { shift->{list}[shift] }
sub last_step { return shift->{list}[ -1 ] }

sub index_of {
    my ( $self, $key ) = @_;
    my ( $step, $tag ) = split /@/ => $key, 2;

    if ($step eq '') {
        # Just want the step with the associated tag.
        my $idx = $self->{lookup}{'@' . $tag} or return undef;
        return $idx->[0];
    }

    my $idx = $self->{lookup}{$step} or return undef;
    if (defined $tag) {
        # Wanted for a step as of a specific tag.
        my $tag_idx = $self->{lookup}{ '@' . $tag }
            or croak qq{Unknown tag: "$tag"};
        $tag_idx = $tag_idx->[0];
        for my $i (reverse @{ $idx }) {
            return $i if $i <= $tag_idx;
        }
        return undef;
    } else {
        # Just want index for a step name. Fail if there are multiple.
        return $idx->[0] if @{ $idx } < 2;
        croak qq{Key "$key" at multiple indexes};
    }
}

sub first_index_of {
    my ( $self, $step, $tag ) = @_;

    # Just return the first index if no tag.
    my $idx = $self->{lookup}{$step} or return undef;
    return $idx->[0] unless defined $tag;

    # Find the tag index.
    my $tag_index = $self->index_of($tag) // croak qq{Unknown tag: "$tag"};

    # Return the first step after the tag.
    return List::Util::first { $_ > $tag_index } @{ $idx };
}

sub index_of_last_tagged {
    shift->{last_tagged_at};
}

sub last_tagged_step {
    my $self = shift;
    return defined $self->{last_tagged_at}
        ? $self->{list}[ $self->{last_tagged_at} ]
        : undef;
}

sub get {
    my $self = shift;
    my $idx = $self->index_of(@_) // return undef;
    return $self->{list}[ $idx ];
}

sub find {
    my ( $self, $name ) = @_;
    my $idx   = $name =~ /@/
        ? $self->index_of($name)
        : $self->first_index_of($name);
    return defined $idx ? $self->step_at($idx) : undef;
}

sub append {
    my $self   = shift;
    my $list   = $self->{list};
    my $lookup = $self->{lookup};

    for my $step (@_) {
        push @{ $list } => $step;
        push @{ $lookup->{ $step->format_name } } => $#$list;
        $lookup->{ $step->id } = my $pos = [$#$list];

        # Index on the tags, too.
        for my $tag ($step->tags) {
            $lookup->{ $tag->format_name } = $pos;
            $lookup->{ $tag->id }          = $pos;
            $self->{last_tagged_at} = $#$list;
        }
    }

    $lookup->{'@HEAD'} = [$#$list];
    $lookup->{'@ROOT'} = [0];

    return $self;
}

sub index_tag {
    my ( $self, $index, $tag ) = @_;
    my $list   = $self->{list};
    my $lookup = $self->{lookup};
    $lookup->{ $tag->id } = $lookup->{ $tag->format_name } = [$index];
    $self->{last_tagged_at} = $index if $index == $#{ $self->{list} };
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Plan::StepList - Sqitch deployment plan step list

=head1 Synopsis

  my $list = App::Sqitch::Plan::StepList->new(
      $add_roles,
      $add_users,
      $insert_user,
      $insert_user2,
  );

  my @steps = $list->steps;
  my $add_users = $list->step_at(1);
  my $add_users = $list->get('add_users');

  my $insert_user1 = $list->get('insert_user@alpha');
  my $insert_user2 = $list->get('insert_user');

=head1 Description

This module is used internally by L<App::Sqitch::Plan> to manage plan steps.
It's modeled on L<Array::AsHash> and L<Hash::MultiValue>, but makes allowances
for finding steps relative to tags.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::StepList->new( @steps );

Instantiates and returns a App::Sqitch::Plan::StepList object with the list of
steps. Each step should be a L<App::Sqitch::Plan::Step> object. Order will be
preserved but the location of each step will be indexed by its name and ID, as
well as the names and IDs of any associated tags.

=head2 Instance Methods

=head3 C<count>

  my $count = $steplist->count;

Returns the number of steps in the list.

=head3 C<steps>

  my @steps = $steplist->steps;

Returns all of the steps in the list.

=head3 C<items>

  my @steps = $steplist->items;

An alias for C<steps>.

=head3 C<step_at>

  my $step = $step_list->step_at(10);

Returns the step at the specified index.

=head3 C<index_of>

  my $index = $steplist->index_of($step_id);
  my $index = $steplist->index_of($step_name);

Returns the index of the step with the specified ID or name. The value passed
may be one of these forms:

=over

=item * An ID

  my $index = $steplist->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');

This is the SHA1 ID of a step or tag. Currently, the full 40-character hexed
hash string must be specified.

=item * A step name

  my $index = $steplist->index_of('users_table');

The name of a step. Will throw an exception if the more then one step in the
list goes by that name.

=item * A tag name

  my $index = $steplist->index_of('@beta1');

The name of a tag, including the leading C<@>.

=item * A tag-qualified step name

  my $index = $steplist->index_of('users_table@beta1');

The named step as it was last seen in the list before the specified tag.

=back

=head3 C<first_index_of>

  my $index = $steplist->first_index_of($step_name);
  my $index = $steplist->first_index_of($step_name, $name);

Returns the index of the first instance of the named step in the list. If a
second argument is passed, the index of the first instance of the step
I<after> the the index of the second argument will be returned. This is useful
for getting the index of a step as it was deployed after a particular tag, for
example:

  my $index = $steplist->first_index_of('foo', '@beta');
  my $index = $steplist->first_index_of('foo', 'users_table@beta1');

The second argument must unambiguously refer to a single step in the list. As
such, it should usually be a tag name or tag-qualified step name. Returns
C<undef> if the step does not appear in the list, or if it does not appear
after the specified second argument step name.

=head3 C<last_step>

  my $step = $steplist->last_step;

Returns the last step to be appear in the list. Returns C<undef> if the list
contains no steps.

=head3 C<last_tagged_step>

  my $step = $steplist->last_tagged_step;

Returns the last tagged step in the list. Returns C<undef> if the list
contains no tagged steps.

=head3 C<index_of_last_tagged>

  my $index = $steplist->index_of_last_tagged;

Returns the index of the last tagged step in the list. Returns C<undef> if the
list contains no tags.

=head3 C<get>

  my $step = $steplist->get($id);
  my $step = $steplist->get($step_name);
  my $step = $steplist->get($tag_name);

Returns the step for the specified ID or name. The name may be specified as
described for C<index_of()>. An exception will be thrown if more than one step
goes by a specified name. As such, it is best to specify it as unambiguously
as possible: as a tag name, a tag-qualified step name, or an ID.

=head3 C<find>

  my $step = $steplist->find($id);
  my $step = $steplist->find($step_name);
  my $step = $steplist->find($tag_name);
  my $step = $steplist->find("$step_name\@$tag_name");

Tries to find and return a step based on the argument. If no tag is specified,
finds and returns the first instance of the named step. Otherwise, it returns
the step as of the specified tag. Unlike C<get()>, it will not throw an error
if no step can be found, but simply return C<undef>.

=head3 C<append>

  $steplist->append(@steps);

Append one or more steps to the list. Does not check for duplicates, so
use with care.

=head3 C<index_tag>

  $steplist->index_tag($index, $tag);

Index the tag at the specified index. That is, the tag is assumed to be
associated with the step at the specified index, and so the internal look up
table is updated so that the step at that index can be found via the tag's
name and ID.

=head1 See Also

=over

=item L<App::Sqitch::Plan>

The Sqitch plan.

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
