package App::Sqitch::Plan::ChangeList;

use v5.10.1;
use utf8;
use strict;
use List::Util;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);

sub new {
    my $class = shift;
    my $self = bless {
        list           => [],
        lookup         => {},
        last_tagged_at => undef,
    } => $class;
    return $self->append(@_);
}

sub count       { scalar @{ shift->{list} } }
sub changes     { @{ shift->{list} } }
sub tags        { map { $_->tags } @{ shift->{list} } }
sub items       { @{ shift->{list} } }
sub change_at   { shift->{list}[shift] }
sub last_change { return shift->{list}[ -1 ] }

sub index_of {
    my ( $self, $key ) = @_;
    my ( $change, $tag ) = split /@/ => $key, 2;

    if ($change eq '') {
        # Just want the change with the associated tag.
        my $idx = $self->{lookup}{'@' . $tag} or return undef;
        return $idx->[0];
    }

    my $idx = $self->{lookup}{$change} or return undef;
    if (defined $tag) {
        # Wanted for a change as of a specific tag.
        my $tag_idx = $self->{lookup}{ '@' . $tag } or hurl plan => __x(
            'Unknown tag "{tag}"',
            tag => '@' . $tag,
        );
        $tag_idx = $tag_idx->[0];
        for my $i (reverse @{ $idx }) {
            return $i if $i <= $tag_idx;
        }
        return undef;
    } else {
        # Just want index for a change name. Fail if there are multiple.
        return $idx->[0] if @{ $idx } < 2;
        hurl plan => __x(
            'Key {key} at multiple indexes',
            key => $key,
        );
    }
}

sub first_index_of {
    my ( $self, $change, $since ) = @_;

    # Just return the first index if no tag.
    my $idx = $self->{lookup}{$change} or return undef;
    return $idx->[0] unless defined $since;

    # Find the tag index.
    my $since_index = $self->index_of($since) // hurl plan => __x(
        'Unknown change: "{change}"',
        change => $since,
    );

    # Return the first change after the tag.
    return List::Util::first { $_ > $since_index } @{ $idx };
}

sub index_of_last_tagged {
    shift->{last_tagged_at};
}

sub last_tagged_change {
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
    return defined $idx ? $self->change_at($idx) : undef;
}

sub append {
    my $self   = shift;
    my $list   = $self->{list};
    my $lookup = $self->{lookup};

    for my $change (@_) {
        push @{ $list } => $change;
        push @{ $lookup->{ $change->format_name } } => $#$list;
        $lookup->{ $change->id } = my $pos = [$#$list];

        # Index on the tags, too.
        for my $tag ($change->tags) {
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

App::Sqitch::Plan::ChangeList - Sqitch deployment plan change list

=head1 Synopsis

  my $list = App::Sqitch::Plan::ChangeList->new(
      $add_roles,
      $add_users,
      $insert_user,
      $insert_user2,
  );

  my @changes = $list->changes;
  my $add_users = $list->change_at(1);
  my $add_users = $list->get('add_users');

  my $insert_user1 = $list->get('insert_user@alpha');
  my $insert_user2 = $list->get('insert_user');

=head1 Description

This module is used internally by L<App::Sqitch::Plan> to manage plan changes.
It's modeled on L<Array::AsHash> and L<Hash::MultiValue>, but makes allowances
for finding changes relative to tags.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::ChangeList->new( @changes );

Instantiates and returns a App::Sqitch::Plan::ChangeList object with the list of
changes. Each change should be a L<App::Sqitch::Plan::Change> object. Order will be
preserved but the location of each change will be indexed by its name and ID, as
well as the names and IDs of any associated tags.

=head2 Instance Methods

=head3 C<count>

  my $count = $changelist->count;

Returns the number of changes in the list.

=head3 C<changes>

  my @changes = $changelist->changes;

Returns all of the changes in the list.

=head3 C<tags>

  my @tags = $changelist->tags;

Returns all of the tags associated with changes in the list.

=head3 C<items>

  my @changes = $changelist->items;

An alias for C<changes>.

=head3 C<change_at>

  my $change = $change_list->change_at(10);

Returns the change at the specified index.

=head3 C<index_of>

  my $index = $changelist->index_of($change_id);
  my $index = $changelist->index_of($change_name);

Returns the index of the change with the specified ID or name. The value passed
may be one of these forms:

=over

=item * An ID

  my $index = $changelist->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');

This is the SHA1 ID of a change or tag. Currently, the full 40-character hexed
hash string must be specified.

=item * A change name

  my $index = $changelist->index_of('users_table');

The name of a change. Will throw an exception if the more then one change in the
list goes by that name.

=item * A tag name

  my $index = $changelist->index_of('@beta1');

The name of a tag, including the leading C<@>.

=item * A tag-qualified change name

  my $index = $changelist->index_of('users_table@beta1');

The named change as it was last seen in the list before the specified tag.

=back

=head3 C<first_index_of>

  my $index = $changelist->first_index_of($change_name);
  my $index = $changelist->first_index_of($change_name, $name);

Returns the index of the first instance of the named change in the list. If a
second argument is passed, the index of the first instance of the change
I<after> the the index of the second argument will be returned. This is useful
for getting the index of a change as it was deployed after a particular tag, for
example:

  my $index = $changelist->first_index_of('foo', '@beta');
  my $index = $changelist->first_index_of('foo', 'users_table@beta1');

The second argument must unambiguously refer to a single change in the list. As
such, it should usually be a tag name or tag-qualified change name. Returns
C<undef> if the change does not appear in the list, or if it does not appear
after the specified second argument change name.

=head3 C<last_change>

  my $change = $changelist->last_change;

Returns the last change to be appear in the list. Returns C<undef> if the list
contains no changes.

=head3 C<last_tagged_change>

  my $change = $changelist->last_tagged_change;

Returns the last tagged change in the list. Returns C<undef> if the list
contains no tagged changes.

=head3 C<index_of_last_tagged>

  my $index = $changelist->index_of_last_tagged;

Returns the index of the last tagged change in the list. Returns C<undef> if the
list contains no tags.

=head3 C<get>

  my $change = $changelist->get($id);
  my $change = $changelist->get($change_name);
  my $change = $changelist->get($tag_name);

Returns the change for the specified ID or name. The name may be specified as
described for C<index_of()>. An exception will be thrown if more than one change
goes by a specified name. As such, it is best to specify it as unambiguously
as possible: as a tag name, a tag-qualified change name, or an ID.

=head3 C<find>

  my $change = $changelist->find($id);
  my $change = $changelist->find($change_name);
  my $change = $changelist->find($tag_name);
  my $change = $changelist->find("$change_name\@$tag_name");

Tries to find and return a change based on the argument. If no tag is specified,
finds and returns the first instance of the named change. Otherwise, it returns
the change as of the specified tag. Unlike C<get()>, it will not throw an error
if more than one change exists with the specified name, but will return the
first instance.

=head3 C<append>

  $changelist->append(@changes);

Append one or more changes to the list. Does not check for duplicates, so
use with care.

=head3 C<index_tag>

  $changelist->index_tag($index, $tag);

Index the tag at the specified index. That is, the tag is assumed to be
associated with the change at the specified index, and so the internal look up
table is updated so that the change at that index can be found via the tag's
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
