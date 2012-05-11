package App::Sqitch::Plan::Tag;

use v5.10.1;
use utf8;
use namespace::autoclean;
use Moose;
use Moose::Meta::Attribute::Native;

has _names => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    traits   => ['Array'],
    init_arg => 'names',
    handles  => { names => 'elements' },
);

has plan => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan',
    weak_ref => 1,
    required => 1,
);

has _steps => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Step]',
    traits   => ['Array'],
    required => 1,
    default  => sub { [] },
    handles  => { steps => 'elements' },
);

sub name { join '/', shift->names }

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan::Tag - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( file => $file );
  while (my $tag = $plan->next) {
      say "Deploy ", join ' ', $tag->names;
      say "Steps: ", join ' ', map { $_->name } $tag->steps;
  }

=head1 Description

A App::Sqitch::Plan::Tag represents a tagged list of deployment steps in a
Sqitch plan. A tag may have one or more names (as multiple tags can represent
a single point in time in the plan), and any number of steps.

These objects are created by L<App::Sqitch::Plan> classes and should not
otherwise be created directly.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan::Tag->new(%params);

Instantiates and returns a App::Sqitch::Plan::Tag object.

=head2 Accessors

=head3 C<names>

  my $names = $tag->names;

Returns a list of the names of the tag.

=head3 C<plan>

  my $plan = $tag->plan;

Returns the plan object with which the tag object is associated.

=head3 C<steps>

  my $steps = $plan->steps;

Returns a list of the deployment steps associated with the tag, in the order
in which they should be deployed.

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
