package App::Sqitch::Plan::NodeList;

use v5.10.1;
use utf8;
use strict;
use Carp;
use List::Util;

sub new {
    my $class = shift;
    my $self = bless {
        list        => [],
        lookup      => {},
        last_tagged => undef,
    } => $class;
    return $self->append(@_);
}

sub count     { scalar @{ shift->{list} } }
sub items     { @{ shift->{list} } }
sub item_at   { shift->{list}[shift] }
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
        return $idx->[-1] if $tag eq 'HEAD';
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
    my $tag_index = $self->index_of($tag) or croak qq{Unknown tag: "$tag"};

    # Return the first node after the tag.
    return List::Util::first { $_ > $tag_index } @{ $idx };
}

sub index_of_last_tagged {
    shift->{last_tagged};
}

sub last_tagged_step {
    my $self = shift;
    return defined $self->{last_tagged}
        ? $self->{list}[ $self->{last_tagged} ]
        : undef;
}

sub get {
    my $self = shift;
    my $idx = $self->index_of(@_) // return undef;
    return $self->{list}[ $idx ];
}

sub append {
    my $self   = shift;
    my $list   = $self->{list};
    my $lookup = $self->{lookup};

    for my $step (@_) {
        push @{ $list } => $step;
        push @{ $lookup->{ $step->format_name } } => $#$list;
        $lookup->{ $step->id } = my $pos = [$#$list];

        if ($step->can('tags')) {
            # Index on the tags, too.
            for my $tag ($step->tags) {
                $lookup->{ $tag->format_name } = $pos;
                $lookup->{ $tag->id }          = $pos;
                $self->{last_tagged} = $#$list;
            }
        }
    }
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Plan::NodeList - Sqitch deployment plan node list

=head1 Synopsis

  my $list = App::Sqitch::Plan::NodeList->new(
      $add_roles,
      $add_users,
      $insert_user,
      $alpha_tag,
      $insert_user2,
  );

  my @nodes = $list->items;
  my $add_users = $list->item_at(1);
  my $add_users = $list->get('add_users');

  my $insert_user1 = $list->get('insert_user', '@alpha');
  my $insert_user2 = $list->get('insert_user', '');

=head1 Description

This module is used internally by L<App::Sqitch::Plan> to manage plan nodes.
It's modeled on L<Array::AsHash> and L<Hash::MultiValue>, but makes allowances
for finding nodes relative to tags.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::NodeList->new( @nodes );

Instantiates and returns a App::Sqitch::Plan::NodeList object with the list of
nodes. Each node should be a L<App::Sqitch::Plan::Step> or
L<App::Sqitch::Plan::Tag> object. Order will be preserved but the location of
each node will be indexed by its formatted name.

=head2 Instance Methods

=head3 C<count>

  my $count = $nodelist->count;

Returns the number of nodes in the list.

=head3 C<items>

  my @nodes = $nodelist->items;

Returns all of the nodes in the list.

=head3 C<item_at>

  my $node = $node_list->item_at(10);

Returns the node at the specified index.

=head3 C<index_of>

  my $index = $nodelist->index_of($node_id);
  my $index = $nodelist->index_of($node_name);

Returns the index of the node with the specified ID or name. The value passed
may be one of these forms:

=over

=item * An ID

  my $index = $nodelist->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');

This is the SHA1 hash of a step or tag. Currently, the full 40-character hexed
hash string must be specified.

=item * A step name

  my $index = $nodelist->index_of('users_table');

The name of a step. Will throw an exception if the named step appears more
than once in the list.

=item * A tag name

  my $index = $nodelist->index_of('@beta1');

The name of a tag, including the leading C<@>.

=item * A tag-qualified step name

  my $index = $nodelist->index_of('users_table@beta1');

The named step as it was last seen in the list before the specified tag.

=back

=head3 C<first_index_of>

  my $index = $nodelist->first_index_of($step_name);
  my $index = $nodelist->first_index_of($step_name, $node_name);

Returns the index of the first instance of the named step in the list. If a
second argument is passed, the index of the first instance of the step
I<after> the the index of the second argument will be returned. This is useful
for getting the index of a step as it was deployed after a particular tag, for
example:

  my $index = $nodelist->first_index_of('foo', '@beta');
  my $index = $nodelist->first_index_of('foo', 'users_table@beta1');

The second argument must unambiguously refer to a single node in the list. As
such, it should usually be a tag name or tag-qualified step name. Returns
C<undef> if the step does not appear in the list, or if it does not appear
after the specified second argument node name.

=head3 C<last_tagged_step>

  my $step = $nodelist->last_tagged_step;

Returns the last tagged step in the list. Returns C<undef> if the list
contains no tagged steps.

=head3 C<last_step>

  my $step = $nodelist->last_step;

Returns the last step to be appear in the list. Returns C<undef> if the list
contains no steps.

=head3 C<index_of_last_tagged>

  my $index = $nodelist->index_of_last_tagged;

Returns the index of the last tagged step in the list. Returns C<undef> if the
list contains no tags.

=head3 C<get>

  my $node = $nodelist->get($node_id);
  my $node = $nodelist->get($node_name);

Returns the node for the specified ID or name. The name may be specified as
described for C<index_of()>. An exception will be thrown if more than one
instance of the node appears. As such, it is best to specify it as
unambiguously as possible: as a tag name or a tag-qualified step name.

=head3 C<append>

  $nodelist->append(@nodes);

Append one or more nodes to the list. Does not check for duplicates, so
use with care.

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
