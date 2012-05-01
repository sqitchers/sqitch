package App::Sqitch::Plan::Tag;

use v5.10.1;
use strict;
use warnings;
use utf8;
use namespace::autoclean;
use Moose;
use Moose::Meta::TypeConstraint::Parameterizable;

has names => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
);

has steps => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
);

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Tag - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan::Tag->new(
      names => \@tag_names,
      steps => \@steps,
  );

=head1 Description

A App::Sqitch::Plan::Tag represents a tagged list of deployment steps in a
Sqitch plan. A tag may have one or more names (as multiple tags can represent
a single point in time in the plan), and any number of steps.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::Tag->new(%params);

Instantiates and returns a App::Sqitch::Plan::Tag object.

=head2 Accessors

=head3 C<names>

  my $names = $plan->names;

Returns an array reference of the names of the tag.

=head3 C<names>

  my $steps = $plan->steps;

Returns an array reference of deployment steps.

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
