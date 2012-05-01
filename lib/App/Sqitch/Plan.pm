package App::Sqitch::Plan;

use v5.10.1;
use strict;
use warnings;
use utf8;
use IO::File;
use App::Sqitch::Plan::Tag;
use namespace::autoclean;
use Moose;
use Moose::Meta::TypeConstraint::Parameterizable;

our $VERSION = '0.30';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
);

has plan => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Tag]',
    lazy     => 1,
    required => 1,
    default  => sub {
        my $self   = shift;
        my $sqitch = $self->sqitch;
        my $file   = $sqitch->plan_file;
        return [] unless -f $file;
        return $self->_parse($file);
    },
);

has position => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => -1,
);


sub _parse {
    my ($self, $file) = @_;
    my $fh = IO::File->new($file, '<:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );

    my (@plan, @tags, @steps);
    LINE: while (my $line = $fh->getline) {
        # Ignore empty lines and comment-only lines.
        next LINE if $line =~ /\A\s*(?:#|$)/;
        chomp $line;

        # Remove inline comments
        $line =~ s/\s*#.*$//g;
        chomp $line;

        # Handle tag headers
        if (my ($names) = $line =~ /^\s*\[\s*(.+?)\s*\]\s*$/) {
            push @plan => App::Sqitch::Plan::Tag->new(
                names => [@tags],
                steps => [@steps],
            ) if @tags;
            @steps = ();
            @tags  = split /\s+/ => $names;
            next LINE;
        }

        # Push the step into the plan.
        if (my ($step) = $line =~ /^\s*(\S+)$/) {
            # Fail if we've seen no tags.
            $self->sqitch->fail(
                "Syntax error in $file at line ",
                $fh->input_line_number, qq{: step "$step" not associated with a tag}
            ) unless @tags;

            push @steps => $step;
            next LINE;
        }

        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number, qq{: "$line"}
        );
    }

    push @plan => App::Sqitch::Plan::Tag->new(
        names => \@tags,
        steps => \@steps,
    ) if @tags;

    return \@plan;
}

sub seek {
    my ($self, $name) = @_;
    # XXX May want to optimize this by indexing tags in _parse().
    my $i = -1;
    for my $tag (@{ $self->plan }) {
        $i++;
        next unless grep { $_ eq $name} @{ $tag->names };
        $self->position($i);
        return $self;
    }
    $self->sqitch->fail(qq{Cannot find tag "$name" in plan});
}

sub reset {
    my $self = shift;
    $self->position(-1);
    return $self;
}

sub next {
    my $self = shift;
    if (my $next = $self->peek) {
        $self->position($self->position + 1);
        return $next;
    }
    $self->position($self->position + 1) if defined $self->current;
    return undef;
}

sub current {
    my $self = shift;
    return $self->plan->[$self->position] if $self->position >= 0;
    return undef;
}

sub peek {
    my $self = shift;
    $self->plan->[$self->position + 1];
}

sub all {
    @{ shift->plan }
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan - Sqitch Deployment Plan

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( file => $file );
  while (my $tag = $plan->next) {
      say "Deploy ", join' ', @{ $tag->names };
  }

=head1 Description

App::Sqitch::Plan provides the interface for a Sqitch plan. It parses a plan
file and provides an iteration interface for working with the plan.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan->new(%params);

Instantiates and returns a App::Sqitch::Plan object.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the plan.

=head3 C<plan>

  my $plan = $plan->plan;

Returns the plan.

=head3 C<position>

Returns the current position of the iterator. This is an integer that's used
as an index into plan. If C<next()> has not been called, or if C<reset()> has
been called, the value will be -1, meaning it is outside of the plan. When
C<next> returns C<undef>, the value will be the last index in the plan plus 1.

=head2 Instance Methods

=head3 C<seek>

  $plan->seek($tag_name);

Move the plan position to the specified tag. Dies if the tag cannot be found
in the plan.

=head3 C<reset>

   $plan->reset;

Resets iteration. Same as C<$plan->position(-1)>, but better.

=head3 C<next>

  while (my $tag = $plan->next) {
      say "Deploy ", join' ', @{ $tag->names };
  }

Returns the next L<App::Sqitch::Plan::Tag> in the plan. Returns C<undef> if
there are no more tags.

=head3 C<current>

   my $tag = $plan->current;

Returns the same tag as was last returned by C<next()>. Returns undef if
C<next()> has not been called or if the plan has been reset.

=head3 C<peek>

   my $tag = $plan->peek;

Returns the next tag in the plan, without incrementing the iterator. Returns
C<undef> if there are no more tags beyond the current tag.

=head3 C<all>

  my @tags = $plan->all;

Returns all of the tags in the plan. This constitutes the entire plan.

=head3 C<do>

  $plan->do(sub { say $_[0]->names->[0]; return $_[0]; });
  $plan->do(sub { say $_->names->[0];    return $_;    });

Pass a code reference to this method to execute it for each tag in the plan.
Each item will be set to C<$_> before executing the code reference, and will
also be passed as the sole argument to the code reference. If C<next()> has
been called prior to the call to C<do()>, then only the remaining items in the
iterator will passed to the code reference. Iteration terminates when the code
reference returns false, so be sure to have it return a true value if you want
it to iterate over every item.

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
