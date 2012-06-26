package App::Sqitch::Plan::Tag;

use v5.10.1;
use utf8;
use namespace::autoclean;
use Moose;
use Encode;
use parent 'App::Sqitch::Plan::Line';

sub format_name {
    '@' . shift->name;
}

has info => (
    is       => 'ro',
    isa      => 'Str',
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;

        return join "\n", (
            'project ' . $self->plan->sqitch->uri->canonical,
            'tag '     . $self->format_name,
            'change '    . $self->change->id,
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
            'tag ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

has change => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::Change',
    weak_ref => 1,
    required => 1,
);

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Tag - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
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
