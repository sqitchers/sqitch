package App::Sqitch::Engine;

use v5.10;
use strict;
use warnings;
use utf8;
use Try::Tiny;
use namespace::autoclean;
use Moose;

has sqitch => (is => 'ro', isa => 'App::Sqitch', required => 1);

sub load {
    my ($class, $p) = @_;

    # We should have a command.
    die 'Missing "engine" parameter to load()' unless $p->{engine};

    # Load the engine class.
    my $pkg = __PACKAGE__ . "::$p->{engine}";
    eval "require $pkg" or die $@;
    return $pkg->new(sqitch => $p->{sqitch});
}

sub name {
    my $class = ref $_[0] || shift;
    return '' if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    return $class;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Engine - Sqitch Deployment Engine

=head1 Synopsis

  my $engine = App::Sqitch::Engine->new( sqitch => $sqitch );

=head1 Description

App::Sqitch::Engine provides the base class for all Sqitch storage engines.

=head1 Interface

=head2 Constructors

=head3 C<load>

  my $cmd = App::Sqitch::Engine->load(%params);

A factory method for instantiating Sqitch engines. It loads the subclass for
the specified engine and calls C<new>, passing the Sqitch object. Supported
parameters are:

=over

=item C<sqitch>

The App::Sqitch object driving the whole thing.

=back

=head3 C<new>

  my $engine = App::Sqitch::Engine->new(%params);

Instantiates and returns a App::Sqitch::Engine object.

=head2 Instance Methods

=head3 C<name>

  my $name = $engine->name;

The name of the engine. Defaults to the last part of the package name, so as a
rule you should not need to override it, since it is that string that Sqitch
uses to find the engine class.

=head1 See Also

=over

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
