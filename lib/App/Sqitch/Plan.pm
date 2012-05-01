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
                index => scalar @plan,
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
        index => scalar @plan,
    ) if @tags;

    return \@plan;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan - Sqitch Deployment Plan

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( file => $file );

=head1 Description

App::Sqitch::Plan provides the interface for a Sqitch plan. This is just a
stub class for now, it doesn't do anything yet.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan->new(%params);

Instantiates and returns a App::Sqitch::Plan object.

=head2 Accessors

=head3 C<file>

  my $file = $plan->file;

Returns the path to the plan file. Defaults to F<./sqitch.plan>. The plan
file may not actually exist on the file system.

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
