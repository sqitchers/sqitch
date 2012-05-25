package App::Sqitch::Plan;

use v5.10.1;
use utf8;
use App::Sqitch::Plan::Tag;
use App::Sqitch::Plan::Step;
use App::Sqitch::Plan::Blank;
use Path::Class;
use Array::AsHash;
use namespace::autoclean;
use Moose;
use Moose::Meta::TypeConstraint::Parameterizable;

our $VERSION = '0.32';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
);

has _plan => (
    is         => 'ro',
    isa        => 'HashRef',
    builder    => 'load',
    init_arg   => 'plan',
    lazy       => 1,
    required   => 1,
);

has position => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => -1,
);

sub load {
    my $self = shift;
    my $file = $self->sqitch->plan_file;
    return {} unless -f $file;
    my $fh = $file->open('<:encoding(UTF-8)')
        or $self->sqitch->fail( "Cannot open $file: $!" );
    return $self->_parse($file, $fh);
}

sub _parse {
    my ( $self, $file, $fh ) = @_;

    my @lines;         # List of lines.
    my @nodes;         # List of nodes.
    my @steps;         # List of steps.
    my %seen;          # Maps tags and steps to line numbers.
    my %tag_steps;     # Maps steps in current tag section to line numbers.

    LINE: while ( my $line = $fh->getline ) {
        chomp $line;

        # Grab blank lines first.
        if ($line =~ /\A(?<lspace>\s*)(?:#(?<comment>.+)|$)/) {
            my $line = App::Sqitch::Plan::Blank->new( plan => $self, %+ );
            push @lines, $line => $line;
            next LINE;
        }

        # Is it a tag or a step?
        my $type = $line =~ /^[@]/ ? 'tag' : 'step';

        # Grab inline comment.
        $line =~ s/(?<rspace>[[:blank:]]*)(?:[#](?<comment>.*))?$//;
        my %params = %+;

        my ($name) = $line =~ /
           ^                              # Beginning of line
           (?<lspace>[[:blank:]]*)?       # Optional leading space
           [@]?                           # Optional @
           (?<name>                       # followed by name consisting of...
               [^[:punct:]]               #     not punct
               (?:                        #     followed by...
                   [^[:blank:]]*?         #         any number non-blank
                   [^[:punct:][:blank:]]  #         one not blank or punct
               )?                         #     ... optionally
           )                              # ... required
           $                              # end of line
        /x;

        %params = (%params, %+);

        # Make sure we have a valid name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: Invalid $type "$line"; ${type}s must not begin or },
                'end in punctuation or digits following punctuation',
        ) if !$params{name} || $params{name} =~ /[[:punct:]][[:digit:]]*\z/;

        # It must not be a reserved name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            ': "HEAD" is a reserved name',
        ) if $params{name} eq 'HEAD';

        # Fail on duplicate name.
        my $key = $type eq 'tag' ? '@' . $params{name} : $params{name};
        if (my $at = $seen{$key} || $tag_steps{$key}) {
            $self->sqitch->fail(
                "Syntax error in $file at line ",
                $fh->input_line_number,
                qq{: \u$type "$params{name}" duplicates earlier declaration on line $at},
            );
        }

        if ($type eq 'tag') {
            if (@steps) {
                # Sort all steps up to this tag by their dependencies.
                @steps = $self->sort_steps(\%seen, @steps);
                push @nodes, map { $_->name, $_ } @steps;
                push @lines, map { $_,       $_ } @steps;
                @steps = ();
            }
            my $node = App::Sqitch::Plan::Tag->new( plan => $self, %params );
            push @nodes, $key  => $node;
            push @lines, $node => $node;
            %seen = (%seen, %tag_steps, $key => $fh->input_line_number);
            %tag_steps = ();
        } else {
            $tag_steps{$key} = $fh->input_line_number;
            push @steps => App::Sqitch::Plan::Step->new( plan => $self, %params );
        }
    }

    if (@steps) {
        # Sort and store any remaining steps.
        @steps = $self->sort_steps(\%seen, @steps);
        push @nodes, map { $_->name, $_ } @steps;
        push @lines, map { $_,       $_ } @steps;
    }

    return {
        nodes => Array::AsHash->new({ array => \@nodes }),
        lines => Array::AsHash->new({ array => \@lines }),
    };
}

sub sort_steps {
    my $self = shift;
    my $seen = ref $_[0] eq 'HASH' ? shift : {};

    my %obj;             # maps step names to objects.
    my %pairs;           # all pairs ($l, $r)
    my %npred;           # number of predecessors
    my %succ;            # list of successors
    for my $step (@_) {

        # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
        my $name = $step->name;
        $obj{$name} = $step;
        my $p = $pairs{$name} = {};
        $npred{$name} += 0;

        # XXX Ignoring conflicts for now.
        for my $dep ( $step->requires ) {

            # Skip it if it's a step from an earlier tag.
            next if exists $seen->{$dep};
            $p->{$dep}++;
            $npred{$dep}++;
            push @{ $succ{$name} } => $dep;
        }
    }

    # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
    # Create a list of nodes without predecessors
    my @list = grep { !$npred{$_->name} } @_;

    my @ret;
    while (@list) {
        my $step = pop @list;
        unshift @ret => $step;
        foreach my $child ( @{ $succ{$step->name} } ) {
            unless ( $pairs{$child} ) {
                my $sqitch = $self->sqitch;
                my $type = $child =~ /^[@]/ ? 'tag' : 'step';
                $self->sqitch->fail(
                    qq{Unknown $type "$child" required in },
                    $step->deploy_file,
                );
            }
            push @list, $obj{$child} unless --$npred{$child};
        }
    }

    if ( my @cycles = map { $_->name } grep { $npred{$_->name} } @_ ) {
        my $last = pop @cycles;
        $self->sqitch->fail(
            'Dependency cycle detected beween steps "',
            join( ", ", @cycles ),
            qq{ and "$last"}
        );
    }
    return \@ret;
}

sub open_script {
    my ( $self, $file ) = @_;
    return $file->open('<:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );
}

sub nodes { shift->_plan->{nodes}->values }
sub lines { shift->_plan->{lines}->values }
sub count { shift->_plan->{nodes}->hcount }

sub index_of {
    my ( $self, $name ) = @_;
    return $self->_plan->{nodes}->hindex($name);
}

sub seek {
    my ( $self, $name ) = @_;
    my $index = $self->index_of($name);
    $self->sqitch->fail(qq{Cannot find node "$name" in plan})
        unless defined $index;
    $self->position($index);
    return $self;
}

sub reset {
    my $self = shift;
    $self->position(-1);
    return $self;
}

sub next {
    my $self = shift;
    if ( my $next = $self->peek ) {
        $self->position( $self->position + 1 );
        return $next;
    }
    $self->position( $self->position + 1 ) if defined $self->current;
    return undef;
}

sub current {
    my $self = shift;
    my $pos = $self->position;
    return if $pos < 0;
    $self->_plan->{nodes}->value_at( $pos );
}

sub peek {
    my $self = shift;
    $self->_plan->{nodes}->value_at( $self->position + 1 );
}

sub last {
    shift->_plan->{nodes}->value_at( -1 );
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

sub write_to {
    my ( $self, $file ) = @_;

    my $fh = IO::File->new(
        $file,
        '>:encoding(UTF-8)'
    ) or $self->sqitch->fail( "Cannot open $file: $!" );
    $fh->print( '# Generated by Sqitch v', App::Sqitch->VERSION, ".\n#\n\n" );

    for my $line ($self->lines) {
        $fh->say($line->stringify);
    }

    $fh->close or die "Error closing $file: $!\n";
    return $self;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan - Sqitch Deployment Plan

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( file => $file );
  while (my $node = $plan->next) {
      if ( $node->isa('App::Sqitch::Plan::Tag') ) {
          say "Tag ", $node->format_name;
      } else {
          say "Deploy ", $node->format_name;
      }
  }

=head1 Description

App::Sqitch::Plan provides the interface for a Sqitch plan. It parses a plan
file and provides an iteration interface for working with the plan.

=head1 Interface

=head2 Constructors

=head3 C<new>

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );

Instantiates and returns a App::Sqitch::Plan object. Takes a single parameter:
an L<App::Sqitch> object.

=head2 Accessors

=head3 C<sqitch>

  my $sqitch = $cmd->sqitch;

Returns the L<App::Sqitch> object that instantiated the plan.

=head3 C<position>

Returns the current position of the iterator. This is an integer that's used
as an index into plan. If C<next()> has not been called, or if C<reset()> has
been called, the value will be -1, meaning it is outside of the plan. When
C<next> returns C<undef>, the value will be the last index in the plan plus 1.

=head2 Instance Methods

=head3 C<index_of>

  my $tag_index  = $paln->index_of('@foo');
  my $step_index = $paln->index_of('bar');

Returns the index of the specified tag or step name. If no such tag or step
exists, C<undef> will be returned.

=head3 C<seek>

  $plan->seek('@foo');
  $plan->seek('bar');

Move the plan position to the specified tag or step. Dies if the tag or step
cannot be found in the plan.

=head3 C<reset>

   $plan->reset;

Resets iteration. Same as C<< $plan->position(-1) >>, but better.

=head3 C<next>

  while (my $node = $plan->next) {
      if ( $node->isa('App::Sqitch::Plan::Tag') ) {
          say "Tag ", $node->format_name;
      } else {
          say "Deploy ", $node->format_name;
      }
  }

Returns the next L<App::Sqitch::Plan::Tag> or L<App::Sqitch::Plan::Step> in
the plan. Returns C<undef> if there are no more nodes.

=head3 C<last>

  my $tag = $plan->last;

Returns the last node in the plan. Does not change the current position.

=head3 C<current>

   my $tag = $plan->current;

Returns the same node as was last returned by C<next()>. Returns C<undef> if
C<next()> has not been called or if the plan has been reset.

=head3 C<peek>

   my $tag = $plan->peek;

Returns the next node in the plan without incrementing the iterator. Returns
C<undef> if there are no more nodes beyond the current node.

=head3 C<nodes>

  my @nodes = $plan->nodes;

Returns all of the nodes in the plan. This constitutes the entire plan.

=head3 C<count>

  my $count = $plan->count;

Returns the number of steps and tags in the plan.

=head3 C<lines>

  my @lines = $plan->lines;

Returns all of the lines in the plan. This includes all nodes as well as
L<App::Sqitch::Plan::Blank>s, which are lines that are neither steps nor tags.

=head3 C<do>

  $plan->do(sub { say $_[0]->name; return $_[0]; });
  $plan->do(sub { say $_->name;    return $_;    });

Pass a code reference to this method to execute it for each node in the plan.
Each node will be stored in C<$_> before executing the code reference, and
will also be passed as the sole argument. If C<next()> has been called prior
to the call to C<do()>, then only the remaining nodes in the iterator will
passed to the code reference. Iteration terminates when the code reference
returns false, so be sure to have it return a true value if you want it to
iterate over every node.

=head3 C<write_to>

  $plan->write_to($file);

Write the plan to the named file, including. comments and white space from the
original plan file.

=head3 C<open_script>

  my $file_handle = $plan->open_script( $step->deploy_file );

Opens the script file passed to it and returns a file handle for reading. The
script file must be encoded in UTF-8.

=head3 C<load>

  my $tags = $plan->load;

Loads the plan. Called internally, not meant to be called directly, as it
parses the plan file and deploy scripts every time it's called. If you want
the all of the nodes, call C<nodes()> instead.

=head3 C<sort_steps>

  @steps = $plan->sort_steps(@steps);
  @steps = $plan->sort_steps( { '@foo' => 1, 'bar' => 1 }, @steps );

Sorts the steps passed in in dependency order and returns them. If the first
argument is a hash reference, its keys should be previously-seen step and tag
names that can be assumed to be satisfied requirements for the succeeding
steps.

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
