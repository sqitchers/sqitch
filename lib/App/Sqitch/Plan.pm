package App::Sqitch::Plan;

use v5.10.1;
use utf8;
use App::Sqitch::Plan::Tag;
use App::Sqitch::Plan::Change;
use App::Sqitch::Plan::Blank;
use App::Sqitch::Plan::Pragma;
use Path::Class;
use App::Sqitch::Plan::ChangeList;
use App::Sqitch::Plan::LineList;
use namespace::autoclean;
use Moose;
use constant SYNTAX_VERSION => '1.0.0-a1';

our $VERSION = '0.50';

has sqitch => (
    is       => 'ro',
    isa      => 'App::Sqitch',
    required => 1,
    weak_ref => 1,
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
    # XXX Issue a warning if file does not exist?
    return {
        changes => App::Sqitch::Plan::ChangeList->new,
        lines => App::Sqitch::Plan::LineList->new(
            $self->_version_line,
        ),
    } unless -f $file;
    my $fh = $file->open('<:encoding(UTF-8)')
        or $self->sqitch->fail( "Cannot open $file: $!" );
    return $self->_parse($file, $fh);
}

sub _parse {
    my ( $self, $file, $fh ) = @_;

    my @lines;         # List of lines.
    my @changes;         # List of changes.
    my @curr_changes;    # List of changes since last tag.
    my %line_no_for;   # Maps tags and changes to line numbers.
    my %change_named;    # Maps change names to change objects.
    my %tag_changes;     # Maps changes in current tag section to line numbers.
    my $seen_version;  # Have we seen a version pragma?
    my $prev_tag;      # Last seen tag.
    my $prev_change;     # Last seen change.

    LINE: while ( my $line = $fh->getline ) {
        chomp $line;

        # Grab blank lines first.
        if ($line =~ /\A(?<lspace>[[:blank:]]*)(?:#(?<comment>.+)|$)/) {
            my $line = App::Sqitch::Plan::Blank->new( plan => $self, %+ );
            push @lines => $line;
            next LINE;
        }

        # Grab inline comment.
        $line =~ s/(?<rspace>[[:blank:]]*)(?:[#](?<comment>.*))?$//;
        my %params = %+;

        # Grab pragmas.
        if ($line =~ /
           \A                             # Beginning of line
           (?<lspace>[[:blank:]]*)?       # Optional leading space
           [%]                            # Required %
           (?<hspace>[[:blank:]]*)?       # Optional space
           (?<name>                       # followed by name consisting of...
               [^[:punct:]]               #     not punct
               (?:                        #     followed by...
                   [^[:blank:]=]*?        #         any number non-blank, non-=
                   [^[:punct:][:blank:]]  #         one not blank or punct
               )?                         #     ... optionally
           )                              # ... required
           (?:                            # followed by value consisting of...
               (?<lopspace>[[:blank:]]*)  #     Optional blanks
               (?<operator>=)             #     Required =
               (?<ropspace>[[:blank:]]*)  #     Optional blanks
               (?<value>.+)               #     String value
           )?                             # ... optionally
           $                              # end of line
        /x) {
            if ($+{name} eq 'syntax-version') {
                # Set explicit version in case we write it out later. In
                # future releases, may change parsers depending on the
                # version.
                $params{value} = SYNTAX_VERSION;
                $seen_version = 1;
            }
            my $prag = App::Sqitch::Plan::Pragma->new( plan => $self, %+, %params );
            push @lines => $prag;
            next LINE;
        }

        # Is it a tag or a change?
        my $type = $line =~ /^[[:blank:]]*[@]/ ? 'tag' : 'change';
        my $name_re = qr/
             [^[:punct:]]               #     not punct
             (?:                        #     followed by...
                 [^[:blank:]@]*         #         any number non-blank, non-@
                 [^[:punct:][:blank:]]  #         one not blank or punct
             )?                         #     ... optionally
        /x;

        $line =~ /
           ^                                    # Beginning of line
           (?<lspace>[[:blank:]]*)?             # Optional leading space
           (?:                                  # followed by...
               [@]                              #     @ for tag
           |                                    # ...or...
               (?<lopspace>[[:blank:]]*)        #     Optional blanks
               (?<operator>[+-])                #     Required + or -
               (?<ropspace>[[:blank:]]*)        #     Optional blanks
           )?                                   # ... optionally
           (?<name>$name_re)                    # followed by name
           (?:                                  # followed by...
               (?<pspace>[[:blank:]]+)          #     Blanks
               (?<dependencies>.+)              # Other stuff
           )?                                   # ... optionally
           $                                    # end of line
        /x;

        %params = ( %params, %+ );

        # Make sure we have a valid name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: Invalid $type "$line"; ${type}s must not begin with },
            'punctuation or end in punctuation or digits following punctuation'
        ) if !$params{name} || $params{name} =~ /[[:punct:]][[:digit:]]*\z/;

        # It must not be a reserved name.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: "$params{name}" is a reserved name},
        ) if $params{name} eq 'HEAD' || $params{name} eq 'ROOT';

        # It must not loo, like a SHA1 hash.
        $self->sqitch->fail(
            "Syntax error in $file at line ",
            $fh->input_line_number,
            qq{: "$params{name}" is invalid because it could be confused with a SHA1 ID},
        ) if $params{name} =~ /^[0-9a-f]{40}/;

        if ($type eq 'tag') {
            # Fail if no changes.
            unless ($prev_change) {
                $self->sqitch->fail(
                    "Error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" declared without a preceding change},
                );
            }

            # Fail on duplicate tag.
            my $key = '@' . $params{name};
            if ( my $at = $line_no_for{$key} ) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" duplicates earlier declaration on line $at},
                );
            }

            # Fail on dependencies.
            if ($params{dependencies}) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    ': Tags may not specify dependencies'
                );
            }

            if (@curr_changes) {
                # Sort all changes up to this tag by their dependencies.
                push @changes => $self->sort_changes(\%line_no_for, @curr_changes);
                @curr_changes = ();
            }

            # Create the tag and associate it with the previous change.
            $prev_tag = App::Sqitch::Plan::Tag->new(
                plan => $self,
                change => $prev_change,
                %params,
            );

            # Keep track of everything and clean up.
            $prev_change->add_tag($prev_tag);
            push @lines => $prev_tag;
            %line_no_for = (%line_no_for, %tag_changes, $key => $fh->input_line_number);
            %tag_changes = ();
        } else {
            # Fail on duplicate change since last tag.
            if ( my $at = $tag_changes{ $params{name} } ) {
                $self->sqitch->fail(
                    "Syntax error in $file at line ",
                    $fh->input_line_number,
                    qq{: \u$type "$params{name}" duplicates earlier declaration on line $at},
                );
            }

            # Got dependencies?
            if (my $deps = $params{dependencies}) {
                my (@req, @con);
                for my $dep (split /[[:blank:]]+/, $deps) {
                    $self->sqitch->fail(
                        "Syntax error in $file at line ",
                        $fh->input_line_number,
                        qq{: "$dep" does not look like a dependency.\n},
                        qq{Dependencies must begin with ":" or "!" and be valid change names},
                    ) unless $dep =~ /^([:!])((?:(?:$name_re)?[@])?$name_re)$/g;
                    if ($1 eq ':') {
                        push @req => $2;
                    } else {
                        push @con => $2;
                    }
                }
                $params{requires}  = \@req;
                $params{conflicts} = \@con;
            }

            $tag_changes{ $params{name} } = $fh->input_line_number;
            push @curr_changes => $prev_change = App::Sqitch::Plan::Change->new(
                plan => $self,
                ( $prev_tag ? ( since_tag => $prev_tag ) : () ),
                %params,
            );
            push @lines => $prev_change;

            if (my $duped = $change_named{ $params{name} }) {
                # Mark previously-seen change of same name as duped.
                $duped->suffix($prev_tag->format_name);
            }
            $change_named{ $params{name} } = $prev_change;
        }
    }

    # Sort and store any remaining changes.
    push @changes => $self->sort_changes(\%line_no_for, @curr_changes) if @curr_changes;

    # We should have a version pragma.
    unshift @lines => $self->_version_line unless $seen_version;

    return {
        changes => App::Sqitch::Plan::ChangeList->new(@changes),
        lines => App::Sqitch::Plan::LineList->new(@lines),
    };
}

sub _version_line {
    App::Sqitch::Plan::Pragma->new(
        plan     => shift,
        name     => 'syntax-version',
        operator => '=',
        value    => SYNTAX_VERSION,
    );
}

sub sort_changes {
    my $self = shift;
    my $seen = ref $_[0] eq 'HASH' ? shift : {};

    my %obj;             # maps change names to objects.
    my %pairs;           # all pairs ($l, $r)
    my %npred;           # number of predecessors
    my %succ;            # list of successors
    for my $change (@_) {

        # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
        my $name = $change->name;
        $obj{$name} = $change;
        my $p = $pairs{$name} = {};
        $npred{$name} += 0;

        # XXX Ignoring conflicts for now.
        for my $dep ( $change->requires ) {

            # Skip it if it's a change from an earlier tag.
            next if exists $seen->{$dep};
            $p->{$dep}++;
            $npred{$dep}++;
            push @{ $succ{$name} } => $dep;
        }
    }

    # Stolen from http://cpansearch.perl.org/src/CWEST/ppt-0.14/bin/tsort.
    # Create a list of changes without predecessors
    my @list = grep { !$npred{$_->name} } @_;

    my @ret;
    while (@list) {
        my $change = pop @list;
        unshift @ret => $change;
        foreach my $child ( @{ $succ{$change->name} } ) {
            unless ( $pairs{$child} ) {
                my $sqitch = $self->sqitch;
                $self->sqitch->fail(
                    qq{Unknown change "$child" required in },
                    $change->deploy_file,
                );
            }
            push @list, $obj{$child} unless --$npred{$child};
        }
    }

    if ( my @cycles = map { $_->name } grep { $npred{$_->name} } @_ ) {
        my $last = pop @cycles;
        $self->sqitch->fail(
            'Dependency cycle detected beween changes "',
            join( ", ", @cycles ),
            qq{ and "$last"}
        );
    }
    return @ret;
}

sub open_script {
    my ( $self, $file ) = @_;
    return $file->open('<:encoding(UTF-8)') or $self->sqitch->fail(
        "Cannot open $file: $!"
    );
}

sub lines          { shift->_plan->{lines}->items }
sub changes        { shift->_plan->{changes}->changes }
sub tags           { shift->_plan->{changes}->tags }
sub count          { shift->_plan->{changes}->count }
sub index_of       { shift->_plan->{changes}->index_of(shift) }
sub get            { shift->_plan->{changes}->get(shift) }
sub find           { shift->_plan->{changes}->find(shift) }
sub first_index_of { shift->_plan->{changes}->first_index_of(@_) }
sub change_at      { shift->_plan->{changes}->change_at(shift) }
sub last_tagged_change { shift->_plan->{changes}->last_tagged_change }

sub seek {
    my ( $self, $key ) = @_;
    my $index = $self->index_of($key);
    $self->sqitch->fail(qq{Cannot find change "$key" in plan})
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
    $self->_plan->{changes}->change_at( $pos );
}

sub peek {
    my $self = shift;
    $self->_plan->{changes}->change_at( $self->position + 1 );
}

sub last {
    shift->_plan->{changes}->change_at( -1 );
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

sub add_tag {
    my ( $self, $name ) = @_;
    $name =~ s/^@//;
    $self->_is_valid(tag => $name);

    my $plan  = $self->_plan;
    my $changes = $plan->{changes};
    my $key   = "\@$name";

    $self->sqitch->fail(qq{Tag "$key" already exists})
        if defined $changes->index_of($key);

    my $change = $changes->last_change or $self->sqitch->fail(
        qq{Cannot apply tag "$key" to a plan with no changes}
    );

    my $tag = App::Sqitch::Plan::Tag->new(
        plan => $self,
        name => $name,
        change => $change,
    );

    $change->add_tag($tag);
    $changes->index_tag( $changes->index_of( $change->id ), $tag );
    $plan->{lines}->append( $tag );
    return $tag;
}

sub add {
    my ( $self, $name, $requires, $conflicts ) = @_;
    $self->_is_valid(change => $name);

    my $plan  = $self->_plan;
    my $changes = $plan->{changes};

    if (defined( my $idx = $changes->index_of($name . '@HEAD') )) {
        my $tag_idx = $changes->index_of_last_tagged;
        $self->sqitch->fail(
            qq{Change "$name" already exists.\n},
            'Use "sqitch rework" to copy and rework it'
        );
    }

    my $change = App::Sqitch::Plan::Change->new(
        plan      => $self,
        name      => $name,
        requires  => $requires  ||= [],
        conflicts => $conflicts ||= [],
        (@{ $requires } || @{ $conflicts } ? ( pspace => ' ' ) : ()),
    );

    # Make sure dependencies are specified.
    $self->_check_dependencies($change, 'add');

    # We good.
    $changes->append( $change );
    $plan->{lines}->append( $change );
    return $change;
}

sub rework {
    my ( $self, $name, $requires, $conflicts ) = @_;
    my $plan  = $self->_plan;
    my $changes = $plan->{changes};
    my $idx   = $changes->index_of($name . '@HEAD') // $self->sqitch->fail(
        qq{Change "$name" does not exist.\n},
        qq{Use "sqitch add $name" to add it to the plan},
    );

    my $tag_idx = $changes->index_of_last_tagged;
    $self->sqitch->fail(
        qq{Cannot rework "$name" without an intervening tag.\n},
        'Use "sqitch tag" to create a tag and try again'
    ) if !defined $tag_idx || $tag_idx < $idx;

    my ($tag) = $changes->change_at($tag_idx)->tags;
    unshift @{ $requires ||= [] } => $name . $tag->format_name;

    my $orig = $changes->change_at($idx);
    my $new  = App::Sqitch::Plan::Change->new(
        plan      => $self,
        name      => $name,
        requires  => $requires,
        conflicts => $conflicts ||= [],
        (@{ $requires } || @{ $conflicts } ? ( pspace => ' ' ) : ()),
    );

    # Make sure dependencies are specified.
    $self->_check_dependencies($new, 'rework');

    # We good.
    $orig->suffix($tag->format_name);
    $changes->append( $new );
    $plan->{lines}->append( $new );
    return $new;
}

sub _check_dependencies {
    my ( $self, $change, $action ) = @_;
    my $changes = $self->_plan->{changes};
    for my $req ( $change->requires ) {
        next if defined $changes->index_of($req =~ /@/ ? $req : $req . '@HEAD');
        my $name = $change->name;
        $self->sqitch->fail(
            qq{Cannot $action change "$name": },
            qq{requires unknown change "$req"}
        );
    }
    return $self;
}

sub _is_valid {
    my ( $self, $type, $name ) = @_;
    $self->sqitch->fail(qq{"$name" is a reserved name})
        if $name eq 'HEAD' || $name eq 'ROOT';
    $self->sqitch->fail(
        qq{"$name" is invalid because it could be confused with a SHA1 ID}
    ) if $name =~ /^[0-9a-f]{40}/;

    $self->sqitch->fail(
        qq{"$name" is invalid: ${type}s must not begin with punctuation },
        'or end in punctuation or digits following punctuation'
    ) unless $name =~ /
        ^                          # Beginning of line
        [^[:punct:]]               # not punct
        (?:                        # followed by...
            [^[:blank:]@#]*?       #     any number non-blank, non-@, non-#.
            [^[:punct:][:blank:]]  #     one not blank or punct
        )?                         # ... optionally
        $                          # end of line
    /x && $name !~ /[[:punct:]][[:digit:]]*\z/;
}

sub write_to {
    my ( $self, $file ) = @_;

    my $fh = IO::File->new(
        $file,
        '>:encoding(UTF-8)'
    ) or $self->sqitch->fail( "Cannot open $file: $!" );
    $fh->say($_->as_string) for $self->lines;
    $fh->close or die "Error closing $file: $!\n";
    return $self;
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch::Plan - Sqitch Deployment Plan

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  while (my $change = $plan->next) {
      say "Deploy ", $change->format_name;
  }

=head1 Description

App::Sqitch::Plan provides the interface for a Sqitch plan. It parses a plan
file and provides an iteration interface for working with the plan.

=head1 Interface

=head2 Constants

=head3 C<SYNTAX_VERSION>

Returns the current version of the Sqitch plan syntax. Used for the
C<%sytax-version> pragma.

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

  my $index      = $plan->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');
  my $foo_index  = $plan->index_of('@foo');
  my $bar_index  = $plan->index_of('bar');
  my $bar1_index = $plan->index_of('bar@alpha')
  my $bar2_index = $plan->index_of('bar@HEAD');

Returns the index of the specified change. Returns C<undef> if no such change
exists. The argument may be any one of:

=over

=item * An ID

  my $index = $plan->index_of('6c2f28d125aff1deea615f8de774599acf39a7a1');

This is the SHA1 hash of a change or tag. Currently, the full 40-character hexed
hash string must be specified.

=item * A change name

  my $index = $plan->index_of('users_table');

The name of a change. Will throw an exception if the named change appears more
than once in the list.

=item * A tag name

  my $index = $plan->index_of('@beta1');

The name of a tag, including the leading C<@>.

=item * A tag-qualified change name

  my $index = $plan->index_of('users_table@beta1');

The named change as it was last seen in the list before the specified tag.

=back

=head3 C<get>

  my $change = $plan->get('6c2f28d125aff1deea615f8de774599acf39a7a1');
  my $foo  = $plan->index_of('@foo');
  my $bar  = $plan->index_of('bar');
  my $bar1 = $plan->index_of('bar@alpha')
  my $bar2 = $plan->index_of('bar@HEAD');

Returns the change corresponding to the specified ID or name. The argument may
be in any of the formats described for C<index_of()>.

=head3 C<find>

  my $change = $plan->find('6c2f28d125aff1deea615f8de774599acf39a7a1');
  my $foo  = $plan->index_of('@foo');
  my $bar  = $plan->index_of('bar');
  my $bar1 = $plan->index_of('bar@alpha')
  my $bar2 = $plan->index_of('bar@HEAD');

Finds the change corresponding to the specified ID or name. The argument may be
in any of the formats described for C<index_of()>. Unlike C<get()>, C<find()>
will not throw an error if more than one change exists with the specified name,
but will return the first instance.

=head3 C<first_index_of>

  my $index = $plan->first_index_of($change_name);
  my $index = $plan->first_index_of($change_name, $change_or_tag_name);

Returns the index of the first instance of the named change in the plan. If a
second argument is passed, the index of the first instance of the change
I<after> the the index of the second argument will be returned. This is useful
for getting the index of a change as it was deployed after a particular tag, for
example, to get the first index of the F<foo> change since the C<@beta> tag, do
this:

  my $index = $plan->first_index_of('foo', '@beta');

You can also specify the first instance of a change after another change,
including such a change at the point of a tag:

  my $index = $plan->first_index_of('foo', 'users_table@beta1');

The second argument must unambiguously refer to a single change in the plan. As
such, it should usually be a tag name or tag-qualified change name. Returns
C<undef> if the change does not appear in the plan, or if it does not appear
after the specified second argument change name.

=head3 C<last_tagged_change>

  my $change = $plan->last_tagged_change;

Returns the last tagged change object. Returns C<undef> if no changes have
been tagged.

=head3 C<change_at>

  my $change = $plan->change_at($index);

Returns the change at the specified index.

=head3 C<seek>

  $plan->seek('@foo');
  $plan->seek('bar');

Move the plan position to the specified change. Dies if the change cannot be found
in the plan.

=head3 C<reset>

   $plan->reset;

Resets iteration. Same as C<< $plan->position(-1) >>, but better.

=head3 C<next>

  while (my $change = $plan->next) {
      say "Deploy ", $change->format_name;
  }

Returns the next L<change|App::Sqitch::Plan::Change> in the plan. Returns C<undef>
if there are no more changes.

=head3 C<last>

  my $change = $plan->last;

Returns the last change in the plan. Does not change the current position.

=head3 C<current>

   my $change = $plan->current;

Returns the same change as was last returned by C<next()>. Returns C<undef> if
C<next()> has not been called or if the plan has been reset.

=head3 C<peek>

   my $change = $plan->peek;

Returns the next change in the plan without incrementing the iterator. Returns
C<undef> if there are no more changes beyond the current change.

=head3 C<changes>

  my @changes = $plan->changes;

Returns all of the changes in the plan. This constitutes the entire plan.

=head3 C<tags>

  my @tags = $plan->tags;

Returns all of the tags in the plan.

=head3 C<count>

  my $count = $plan->count;

Returns the number of changes in the plan.

=head3 C<lines>

  my @lines = $plan->lines;

Returns all of the lines in the plan. This includes all the
L<changes|App::Sqitch::Plan::Change>, L<tags|App::Sqitch::Plan::Tag>,
L<pragmas|App::Sqitch::Plan::Pragma>, and L<blank
lines|App::Sqitch::Plan::Blank>.

=head3 C<do>

  $plan->do(sub { say $_[0]->name; return $_[0]; });
  $plan->do(sub { say $_->name;    return $_;    });

Pass a code reference to this method to execute it for each change in the plan.
Each change will be stored in C<$_> before executing the code reference, and
will also be passed as the sole argument. If C<next()> has been called prior
to the call to C<do()>, then only the remaining changes in the iterator will
passed to the code reference. Iteration terminates when the code reference
returns false, so be sure to have it return a true value if you want it to
iterate over every change.

=head3 C<write_to>

  $plan->write_to($file);

Write the plan to the named file, including. comments and white space from the
original plan file.

=head3 C<open_script>

  my $file_handle = $plan->open_script( $change->deploy_file );

Opens the script file passed to it and returns a file handle for reading. The
script file must be encoded in UTF-8.

=head3 C<load>

  my $plan_data = $plan->load;

Loads the plan data. Called internally, not meant to be called directly, as it
parses the plan file and deploy scripts every time it's called. If you want
the all of the changes, call C<changes()> instead.

=head3 C<sort_changes>

  @changes = $plan->sort_changes(@changes);
  @changes = $plan->sort_changes( { '@foo' => 1, 'bar' => 1 }, @changes );

Sorts a list of changes in dependency order and returns them. If the first
argument is a hash reference, its keys should be previously-seen change and tag
names that can be assumed to be satisfied requirements for the succeeding
changes.

=head3 C<add_tag>

  $plan->add_tag('whee');

Adds a tag to the plan. Exits with a fatal error if the tag already
exists in the plan.

=head3 C<add>

  $plan->add( 'whatevs' );
  $plan->add( 'widgets', [qw(foo bar)], [qw(dr_evil)] );

Adds a change to the plan. The second argument specifies a list of required
changes. The third argument specifies a list of conflicting changes. Exits with a
fatal error if the change already exists, or if the any of the dependencies are
unknown.

=head3 C<rework>

  $plan->rework( 'whatevs' );
  $plan->rework( 'widgets', [qw(foo bar)], [qw(dr_evil)] );

Reworks an existing change. Said change must already exist in the plan and be
tagged or have a tag following it or an exception will be thrown. The previous
occurrence of the change will have the suffix of the most recent tag added to
it, and a new tag instance will be added to the list.

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
