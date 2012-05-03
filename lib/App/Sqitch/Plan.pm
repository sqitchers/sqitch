package App::Sqitch::Plan;

use v5.10.1;
use strict;
use warnings;
use utf8;
use IO::File;
use App::Sqitch::Plan::Tag;
use Path::Class;
use namespace::autoclean;
use Moose;
use Moose::Meta::TypeConstraint::Parameterizable;

our $VERSION = '0.30';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
);

has with_untracked => (
    is       => 'ro',
    isa      => 'Bool',
    required => 1,
    default  => 0,
);

has all => (
    is       => 'ro',
    isa      => 'ArrayRef[App::Sqitch::Plan::Tag]',
    auto_deref => 1,
    lazy     => 1,
    required => 1,
    default  => sub { shift->load }
);

has position => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => -1,
);

has _tags => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    default  => sub { {} },
);

sub load {
    my $self = shift;
    my $file = $self->sqitch->plan_file;
    my $plan = -f $file ? $self->_parse($file) : [];
    push @{ $plan } => $self->load_untracked($plan) if $self->with_untracked;
    return $plan;
}

sub _parse {
    my ($self, $file) = @_;
    my $fh = IO::File->new($file, '<:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );

    my $tags = $self->_tags;
    my @plan;       # List of tags to return
    my @curr_tags;  # List of tags in currently-parsing tag section.
    my @curr_steps; # List of steps in currently-parsing tag section.
    my %seen_tags;  # Maps tags to line numbers.
    my %prev_steps; # Maps steps from previous sections to line numbers.
    my %tag_steps;  # Maps steps in current tag section to line numbers.

    LINE: while (my $line = $fh->getline) {
        # Ignore eampty lines and comment-only lines.
        next LINE if $line =~ /\A\s*(?:#|$)/;
        chomp $line;

        # Remove inline comments
        $line =~ s/\s*#.*$//g;
        chomp $line;

        # Handle tag headers
        if (my ($names) = $line =~ /^\s*\[\s*(.+?)\s*\]\s*$/) {
            if (@curr_tags) {
                push @plan => App::Sqitch::Plan::Tag->new(
                    names => [@curr_tags],
                    steps => $self->_sort_steps(\@curr_tags, \%prev_steps, @curr_steps),
                );
                $tags->{$_} = $#plan for @curr_tags;
                %prev_steps = (%prev_steps, %tag_steps);
                @curr_steps = ();
                %tag_steps = ();
            }

            @curr_tags = split /\s+/ => $names;

            for my $t (@curr_tags) {
                # Fail on invalid tag.
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number, qq{: "HEAD+" is a reserved tag name}
                ) if $t eq 'HEAD+';

                # Fail on duplicate tag.
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: Tag "$t" duplicates earlier declaration on line $seen_tags{$t}}
                ) if $seen_tags{$t};

                # We're good.
                $seen_tags{$t} = $fh->input_line_number;
            }

            next LINE;
        }

        # Push the step into the plan.
        if (my ($step) = $line =~ /^\s*(\S+)$/) {

            # Fail if we've seen no tags.
            $self->sqitch->fail(
                "Syntax error in $file at line ",
                $fh->input_line_number, qq{: Step "$step" not associated with a tag}
            ) unless @curr_tags;

            # Fail on duplicate step.
            if (my $line = $tag_steps{$step} || $prev_steps{$step}) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: Step "$step" duplicates earlier declaration on line $line}
                );
            }

            # We're good.
            $tag_steps{$step} = $fh->input_line_number;
            push @curr_steps => $step;
            next LINE;
        }

        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number, qq{: "$line"}
        );
    }

    if (@curr_tags) {
        push @plan => App::Sqitch::Plan::Tag->new(
            names => \@curr_tags,
            steps => $self->_sort_steps(\@curr_tags, \%prev_steps, @curr_steps),
        );
        $tags->{$_} = $#plan for @curr_tags;
    }

    return \@plan;
}

sub load_untracked {
    my ($self, $plan) = @_;
    my $sqitch = $self->sqitch;

    my %steps = map { map { $_ => 1 } @{ $_->steps } } @{ $plan };
    my $ext = $sqitch->extension;
    my $dir = $sqitch->deploy_dir;
    my $skip = scalar $dir->dir_list;
    my @steps;

    # Ignore VCS directories (borrowed from App::Ack).
    my $ignore_dirs = join '|', map { quotemeta } qw(
        .bzr
        .cdv
        ~.dep
        ~.dot
        ~.nib
        ~.plst
        .git
        .hg
        .pc
        .svn
        _MTN
        blib
        CVS
        RCS
        SCCS
        _darcs
        _sgbak
        autom4te.cache
        cover_db
        _build
    );

    require File::Find::Rule;
    my $rule = File::Find::Rule->new;

    $rule = $rule->or(
        # Ignore VCS directories.
        $rule->new
             ->directory
             ->name(qr/^(?:$ignore_dirs)$/)
             ->prune
             ->discard,
        # Find files.
        $rule->new->file->name( qr/[.]\Q$ext\E$/ )->exec(sub {
            my $file = pop;
            if ($skip) {
                # Remove $skip directories from the file name.
                my $fobj = file $file;
                my @dirs = $fobj->dir->dir_list;
                $file = file(
                    @dirs[$skip..$#dirs],
                    $fobj->basename
                )->stringify;
            }

            # Add the file if is is not already in the plan.
            $file =~ s/[.]\Q$ext\E$//;
            push @steps => $file if !$steps{$file}++;
        }),
    );

    # Find the untracked steps.
    $rule->in($sqitch->deploy_dir) or return;

    return App::Sqitch::Plan::Tag->new(
        names => ['HEAD+'],
        steps => \@steps,
    );

    return $self;
}

sub _parse_dependencies {
    my ($self, $tag_names, $step) = @_;
    my $sqitch = $self->sqitch;
    my $fh     = $self->open_script(
        step => $step,
        tags => $tag_names,
        dir  => $sqitch->deploy_dir,
    );

    my $comment = qr{#+|--+|/[*]+|;+};
    my %deps;
    while (my $line = $fh->getline) {
        chomp $line;
        last if $line =~ /\A\s*$/;        # Blank line, no more headers.
        last if $line !~ /\A\s*$comment/; # Must be a comment line.
        my ($label, $value) = $line =~ /$comment\s*:(requires|conflicts):\s*(.+)/;
        push @{ $deps{$label} ||= [] } => split /\s+/ => $value
            if $label && $value;
    }
    return \%deps;
}

sub _sort_steps {
    my ($self, $tag_names, $seen) = (shift, shift, shift);

    my %pairs;	# all pairs ($l, $r)
    my %npred;	# number of predecessors
    my %succ;	# list of successors
    for my $step (@_) {
        my $deps = $self->_parse_dependencies($tag_names, $step);

        # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
        my $p = $pairs{$step} = {};
        $npred{$step} += 0;
        # XXX Ignoring conflicts for now.
        for my $dep (@{ $deps->{requires} || []}) {
            # Skip it if it's a step from an earlier tag.
            next if exists $seen->{$dep};
            $p->{$dep}++;
            $npred{$dep}++;
            push @{$succ{$step}} => $dep;
        }
    }

    # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
    # Create a list of nodes without predecessors
    my @list = grep { !$npred{$_} } @_;

    my @ret;
    while (@list) {
        my $item = pop @list;
        unshift @ret => $item;
        foreach my $child (@{ $succ{$item} }) {
            unless ($pairs{$child}) {
                my $sqitch = $self->sqitch;
                my $file   = $sqitch->deploy_dir->file("$item." . $sqitch->extension);
                $self->sqitch->fail(qq{Unknown step "$child" required in $file});
            }
            push @list, $child unless --$npred{$child};
        }
    }

    if (my @cycles = grep { $npred{$_} } @_) {
        my $last = pop @cycles;
        $self->sqitch->fail(
            'Dependency cycle detected beween steps "',
            join(", ", @cycles), qq{ and "$last"}
        );
    }
    return \@ret;
}

sub open_script {
    my ($self, %p) = @_;
    my $sqitch = $self->sqitch;
    my $file   = $p{dir}->file("$p{step}." . $sqitch->extension);
    return $file->open('<:encoding(UTF-8)') or $sqitch->fail(
        "Cannot open $file: $!"
    );
}

sub seek {
    my ($self, $name) = @_;
    my $index = $self->_tags->{$name};
    $self->sqitch->fail(qq{Cannot find tag "$name" in plan})
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
    if (my $next = $self->peek) {
        $self->position($self->position + 1);
        return $next;
    }
    $self->position($self->position + 1) if defined $self->current;
    return undef;
}

sub current {
    my $self = shift;
    return ($self->all)[$self->position] if $self->position >= 0;
    return undef;
}

sub peek {
    my $self = shift;
    ($self->all)[$self->position + 1];
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

sub write_to {
    my ($self, $file) = @_;

    # Make sure we have a valid plan for writing.
    my @tags = $self->all;
    if (@tags && grep { $_ eq 'HEAD+' } @{ $tags[-1]->names }) {
        $self->sqitch->fail('Cannot write plan with reserved tag "HEAD+"');
    }

    my $fh = IO::File->new($file, '>:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );
    $fh->print('# Generated by Sqitch v', App::Sqitch->VERSION, ".\n#\n\n");

    for my $tag (@tags) {
        $fh->say('[', join(' ', @{ $tag->names }), ']');
        $fh->say($_) for @{ $tag->steps };
        $fh->say;
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

=head3 C<write_to>

  $plan->write_to($file);

Write the plan to the named file. Comments and white space from the original
plan are I<not> preserved, so be careful to alert the user when overwriting an
exiting plan file.

=head3 C<open_script>

  my $file_handle = $plan->open_script(
      step => $step,
      tags => \@tag_names,
      dir  => $sqitch->deploy_dir,
  );

Opens the script corresponding to the named step in the specified directory.
The C<tags> option is ignored, but may be used in subclasses to open a script
at a particular point in VCS history. Returns a file handle for reading. The
script file must be encoded in UTF-8.

=head3 C<parse>

Called internally to populate C<all> by parsing the plan file. Not intended to
be used directly, though it may be overridden in subclasses.

=head3 C<load>

  my $tags = $plan->load;

Loads the plan, including untracked steps (if C<with_untracked> is true).
Called internally, not meant to be called directly, as it parses the plan file
and searches the file system (if C<with_untracked>) every time it's called. If
you want the all of the steps, including untracked, call C<all()> instead.

Subclasses should override this method to load the plan from whatever
resources they deem appropriate.

=head3 C<load_untracked>

  my $tag = $plan->load_untracked($tags);

Loads untracked steps and returns them in a tag object with the single tag
name C<HEAD+>. Pass in an array reference of tracked tags whose steps should
be excluded from the returned untracked. Called internally by C<load()> and
not meant to be called directly, as it will scan the file system on every
call.

Subclasses may override this method to load a tag with untracked steps from
whatever resources they deem appropriate.

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
