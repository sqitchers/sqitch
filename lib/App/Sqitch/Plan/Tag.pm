package App::Sqitch::Plan::Tag;

use v5.10.1;
use utf8;
use namespace::autoclean;
use Moose;
use parent 'App::Sqitch::Plan::Line';

sub format_name {
    '@' . shift->name;
}

has id => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;

        my $content = join "\n", (
            'object ' . $self->step_id,
            'type tag',
            'tag ' . $self->format_name,
            # XXX Add tagger name? Timestamp? Comment?
        );

        require Digest::SHA1;
        return Digest::SHA1->new->add(
            'tag ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

has step_id => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;
        my $index = $plan->index_of($self->format_name);

        while ($index > 0) {
            my $prev = $plan->node_at(--$index);
            return $prev->id if $prev->isa('App::Sqitch::Plan::Step');
        }

        return '0000000000000000000000000000000000000000';
    },
);

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Tag - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->stringify;
  }

=head1 Description

A App::Sqitch::Plan::Tag represents a tag line in the plan file. See
L<App::Sqitch::Plan::Line> for its interface. The only difference is that the
C<format_name> returns the name with a leading C<@>.

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
