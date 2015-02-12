package App::Sqitch::Plan::LineList;

use 5.010;
use strict;
use utf8;

our $VERSION = '0.999_1';

sub new {
    my $class = shift;
    my (@list, %index);
    for my $line (@_) {
        push @list => $line;
        $index{ $line } = $#list;
    }

    return bless {
        list   => \@list,
        lookup => \%index,
    }
}

sub count    { scalar @{ shift->{list} } }
sub items    { @{ shift->{list} } }
sub item_at  { shift->{list}->[shift] }
sub index_of { shift->{lookup}{+shift} }

sub append {
    my ( $self, $line ) = @_;
    my $list = $self->{list};
    push @{ $list } => $line;
    $self->{lookup}{$line} = $#$list;
}

sub insert_at {
    my ( $self, $line, $idx ) = @_;

    # Add the line to the list.
    my $list = $self->{list};
    splice @{ $list }, $idx, 0, $line;

    # Reindex.
    my $index = $self->{lookup};
    $index->{ $list->[$_] } = $_ for $idx..$#$list;
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Plan::LineList - Sqitch deployment plan line list

=head1 Synopsis

  my $list = App::Sqitch::Plan::LineList->new(@lines);

  my @lines = $list->items;
  my $index = $list->index_of($line);

  $lines->append($another_line);

=head1 Description

This module is used internally by L<App::Sqitch::Plan> to manage plan file
lines. It's modeled on L<Array::AsHash>, but is much simpler and hews closer
to the API of L<App::Sqitch::Plan::ChangeList>.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::LineList->new(map { $_->name => @_ } @changes );

Instantiates and returns a App::Sqitch::Plan::LineList object. The parameters
should be a key/value list of lines. Keys may be duplicated, as long as a tag
appears between each instance of a key.

=head2 Instance Methods

=head3 C<count>

=head3 C<items>

=head3 C<item_at>

=head3 C<index_of>

=head3 C<append>

=head3 C<insert_at>

=head1 See Also

=over

=item L<App::Sqitch::Plan>

The Sqitch plan.

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
