package App::Sqitch::Role::ContextCommand;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo::Role;
use Path::Class;
use App::Sqitch::Types qw(ArrayRef);

requires 'options';
requires 'configure';
requires 'target_params';

has _cx => (
    is  => 'ro',
    isa => ArrayRef,
    default => sub { [] },
);

around options => sub {
    my $orig = shift;
    return $orig->(@_), qw(
        plan-file|f=s
        top-dir=s
    );
};

around configure => sub {
    my ( $orig, $class, $config, $opt ) = @_;

    # Grab the target params.
    my @cx = (
        do { my $f = delete $opt->{top_dir};   $f ? ( top_dir   => dir($f))  : () },
        do { my $f = delete $opt->{plan_file}; $f ? ( plan_file => file($f)) : () },
    );

    # Let the command take care of its options.
    my $params = $class->$orig($config, $opt);

    # Hang on to the target parameters.
    $params->{_cx} = \@cx;
    return $params;
};

around target_params => sub {
    my ($orig, $self) = (shift, shift);
    return $self->$orig(@_), @{ $self->_cx };
};

1;

__END__

=head1 Name

App::Sqitch::Role::ContextCommand - A command that needs to know where things are

=head1 Synopsis

  package App::Sqitch::Command::add;
  extends 'App::Sqitch::Command';
  with 'App::Sqitch::Role::ContextCommand';

=head1 Description

This role encapsulates the options and target parameters required by commands
that need to know where to find project files.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::add->options;

Adds contextual options C<--plan-file> and C<--top-dir>.

=head3 C<configure>

Configures the options used for target parameters.

=head2 Instance Methods

=head3 C<target_params>

Returns a list of parameters to be passed to App::Sqitch::Target's C<new>
and C<all_targets> methods.

=head1 See Also

=over

=item L<App::Sqitch::Command::add>

The C<add> command adds changes to the the plan and change scripts to the project.

=item L<App::Sqitch::Command::deploy>

The C<deploy> command deploys changes to a database.

=item L<App::Sqitch::Command::bundle>

The C<bundle> command bundles Sqitch changes for distribution.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2018 iovation Inc.

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
