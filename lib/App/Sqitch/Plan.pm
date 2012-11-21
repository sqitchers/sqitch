package App::Sqitch::Plan;

use 5.010;
use utf8;
use App::Sqitch::DateTime;
use App::Sqitch::Plan::Tag;
use App::Sqitch::Plan::Change;
use App::Sqitch::Plan::Blank;
use App::Sqitch::Plan::Pragma;
use App::Sqitch::Plan::Depend;
use Path::Class;
use App::Sqitch::Plan::ChangeList;
use App::Sqitch::Plan::LineList;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use namespace::autoclean;
use Moose;
use constant SYNTAX_VERSION => '1.0.0-b2';

our $VERSION = '0.939';

# Like [:punct:], but excluding _. Copied from perlrecharclass.
my $punct = q{-!"#$%&'()*+,./:;<=>?@[\\]^`{|}~};
my $name_re = qr{
    (?![$punct])                   # first character isn't punctuation
    (?:                            # start non-capturing group, repeated once or more ...
       (?!                         #     negative look ahead for...
           [~/=%^]                 #         symbolic reference punctuation
           [[:digit:]]+            #         digits
           (?:$|[[:blank:]])       #         eol or blank
       )                           #     ...
       [^[:blank:]:@#]             #     match a valid character
    )+                             # ... end non-capturing group
    (?<![$punct])\b                # last character isn't punctuation
}x;

my %reserved = map { $_ => undef } qw(ROOT HEAD FIRST LAST);

sub name_regex { $name_re }

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

has _changes => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::ChangeList',
    lazy     => 1,
    required => 1,
    default  => sub {
        App::Sqitch::Plan::ChangeList->new(@{ shift->_plan->{changes} }),
    },
);

has _lines => (
    is       => 'ro',
    isa      => 'App::Sqitch::Plan::LineList',
    lazy     => 1,
    required => 1,
    default  => sub {
        App::Sqitch::Plan::LineList->new(@{ shift->_plan->{lines} }),
    },
);

has position => (
    is       => 'rw',
    isa      => 'Int',
    required => 1,
    default  => -1,
);

has project => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->_plan->{pragmas}{project};
    }
);

has uri => (
    is       => 'ro',
    isa      => 'Maybe[URI]',
    required => 0,
    lazy     => 1,
    default  => sub {
        my $uri = shift->_plan->{pragmas}{uri} || return;
        require URI;
        URI->new($uri);
    }
);

sub load {
    my $self = shift;
    my $file = $self->sqitch->plan_file;
    hurl plan => __x('Plan file {file} does not exist', file => $file)
        unless -e $file;
    hurl plan => __x('Plan file {file} is not a regular file', file => $file)
        unless -f $file;
    my $fh = $file->open('<:encoding(UTF-8)') or hurl plan => __x(
        'Cannot open {file}: {error}',
        file  => $file,
        error => $!
    );
    return $self->_parse($file, $fh);
}

sub _parse {
    my ( $self, $file, $fh ) = @_;

    my @lines;         # List of lines.
    my @changes;       # List of changes.
    my @curr_changes;  # List of changes since last tag.
    my %line_no_for;   # Maps tags and changes to line numbers.
    my %change_named;  # Maps change names to change objects.
    my %tag_changes;   # Maps changes in current tag section to line numbers.
    my %pragmas;       # Maps pragma names to values.
    my $seen_version;  # Have we seen a version pragma?
    my $prev_tag;      # Last seen tag.
    my $prev_change;   # Last seen change.

    # Regex to match timestamps.
    my $ts_re = qr/
        (?<yr>[[:digit:]]{4})  # year
        -                      # dash
        (?<mo>[[:digit:]]{2})  # month
        -                      # dash
        (?<dy>[[:digit:]]{2})  # day
        T                      # T
        (?<hr>[[:digit:]]{2})  # hour
        :                      # colon
        (?<mi>[[:digit:]]{2})  # minute
        :                      # colon
        (?<sc>[[:digit:]]{2})  # second
        Z                      # Zulu time
    /x;

    my $planner_re = qr/
        (?<planner_name>[^<]+)    # name
        [[:blank:]]+              # blanks
        <(?<planner_email>[^>]+)> # email
    /x;

    # Use for raising syntax error exceptions.
    my $raise_syntax_error = sub {
        hurl plan => __x(
            'Syntax error in {file} at line {lineno}: {error}',
            file   => $file,
            lineno => $fh->input_line_number,
            error  => shift
        );
    };

    # First, find pragmas.
    HEADER: while ( my $line = $fh->getline ) {
        chomp $line;

        # Grab blank lines first.
        if ($line =~ /\A(?<lspace>[[:blank:]]*)(?:#[[:blank:]]*(?<note>.+)|$)/) {
            my $line = App::Sqitch::Plan::Blank->new( plan => $self, %+ );
            push @lines => $line;
            last HEADER if @lines && !$line->note;
            next HEADER;
        }

        # Grab inline note.
        $line =~ s/(?<rspace>[[:blank:]]*)(?:[#][[:blank:]]*(?<note>.*))?$//;
        my %params = %+;

        $raise_syntax_error->(
            __ 'Invalid pragma; a blank line must come between pragmas and changes'
        ) unless $line =~ /
           \A                             # Beginning of line
           (?<lspace>[[:blank:]]*)?       # Optional leading space
           [%]                            # Required %
           (?<hspace>[[:blank:]]*)?       # Optional space
           (?<name>                       # followed by name consisting of...
               [^$punct]                  #     not punct
               (?:                        #     followed by...
                   [^[:blank:]=]*?        #         any number non-blank, non-=
                   [^$punct[:blank:]]     #         one not blank or punct
               )?                         #     ... optionally
           )                              # ... required
           (?:                            # followed by value consisting of...
               (?<lopspace>[[:blank:]]*)  #     Optional blanks
               (?<operator>=)             #     Required =
               (?<ropspace>[[:blank:]]*)  #     Optional blanks
               (?<value>.+)               #     String value
           )?                             # ... optionally
           \z                             # end of line
        /x;

        # XXX Die if the pragma is a dupe?

        if ($+{name} eq 'syntax-version') {
            # Set explicit version in case we write it out later. In future
            # releases, may change parsers depending on the version.
            $pragmas{syntax_version} = $params{value} = SYNTAX_VERSION;
        } elsif ($+{name} eq 'project') {
            my $proj = $+{value};
            $raise_syntax_error->(__x(
                qq{invalid project name "{project}": project names must not }
                . 'begin with punctuation, contain "@", ":", or "#", or end in '
                . 'punctuation or digits following punctuation',
                project => $proj,
            )) unless $proj =~ /\A$name_re\z/;
            $pragmas{project} = $proj;
        } else {
            $pragmas{ $+{name} } = $+{value} // 1;
        }

        push @lines => App::Sqitch::Plan::Pragma->new(
            plan => $self,
            %+,
            %params
        );
        next HEADER;
    }

    # We should have a version pragma.
    unless ( $pragmas{syntax_version} ) {
        unshift @lines => $self->_version_line;
        $pragmas{syntax_version} = SYNTAX_VERSION;
    }

    # Should have valid project pragma.
    hurl plan => __x(
        'Missing %project pragma in {file}',
        file => $file,
    ) unless $pragmas{project};

    LINE: while ( my $line = $fh->getline ) {
        chomp $line;

        # Grab blank lines first.
        if ($line =~ /\A(?<lspace>[[:blank:]]*)(?:#[[:blank:]]*(?<note>.+)|$)/) {
            my $line = App::Sqitch::Plan::Blank->new( plan => $self, %+ );
            push @lines => $line;
            next LINE;
        }

        # Grab inline note.
        $line =~ s/(?<rspace>[[:blank:]]*)(?:[#][[:blank:]]*(?<note>.*))?$//;
        my %params = %+;

        # Is it a tag or a change?
        my $type = $line =~ /^[[:blank:]]*[@]/ ? 'tag' : 'change';
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
           (?<pspace>[[:blank:]]+)?             #     blanks

           (?:                                  # followed by...
               [[](?<dependencies>[^]]+)[]]     #     dependencies
               [[:blank:]]*                     #    blanks
           )?                                   # ... optionally

           (?:                                  # followed by...
               $ts_re                           #    timestamp
               [[:blank:]]*                     #    blanks
           )?                                   # ... optionally

           (?:                                  # followed by
               $planner_re                      #    planner
           )?                                   # ... optionally
           $                                    # end of line
        /x;

        %params = ( %params, %+ );

        # Raise errors for missing data.
        $raise_syntax_error->(__(
            qq{Invalid name; names must not begin with punctuation, }
            . 'contain "@", ":", or "#", or end in punctuation or digits following punctuation',
        )) if !$params{name}
            || (!$params{yr} && $line =~ $ts_re);

        $raise_syntax_error->(__ 'Missing timestamp and planner name and email')
            unless $params{yr} || $params{planner_name};
        $raise_syntax_error->(__ 'Missing timestamp') unless $params{yr};

        $raise_syntax_error->(__ 'Missing planner name and email')
            unless $params{planner_name};

        # It must not be a reserved name.
        $raise_syntax_error->(__x(
            '"{name}" is a reserved name',
            name => ($type eq 'tag' ? '@' : '') . $params{name},
        )) if exists $reserved{ $params{name} };

        # It must not look like a SHA1 hash.
        $raise_syntax_error->(__x(
            '"{name}" is invalid because it could be confused with a SHA1 ID',
            name => $params{name},
        )) if $params{name} =~ /^[0-9a-f]{40}/;

        # Assemble the timestamp.
        $params{timestamp} = App::Sqitch::DateTime->new(
            year      => delete $params{yr},
            month     => delete $params{mo},
            day       => delete $params{dy},
            hour      => delete $params{hr},
            minute    => delete $params{mi},
            second    => delete $params{sc},
            time_zone => 'UTC',
        );

        if ($type eq 'tag') {
            # Fail if no changes.
            unless ($prev_change) {
                $raise_syntax_error->(__x(
                    'Tag "{tag}" declared without a preceding change',
                    tag => $params{name},
                ));
            }

            # Fail on duplicate tag.
            my $key = '@' . $params{name};
            if ( my $at = $line_no_for{$key} ) {
                $raise_syntax_error->(__x(
                    'Tag "{tag}" duplicates earlier declaration on line {line}',
                    tag  => $params{name},
                    line => $at,
                ));
            }

            # Fail on dependencies.
            $raise_syntax_error->(__x(
                __ 'Tags may not specify dependencies'
            )) if $params{dependencies};

            if (@curr_changes) {
                # Sort all changes up to this tag by their dependencies.
                push @changes => $self->check_changes(
                    $pragmas{project},
                    \%line_no_for,
                    @curr_changes,
                );
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
                $raise_syntax_error->(__x(
                    'Change "{change}" duplicates earlier declaration on line {line}',
                    change => $params{name},
                    line   => $at,
                ));
            }

            # Got dependencies?
            if (my $deps = $params{dependencies}) {
                my (@req, @con);
                for my $depstring (split /[[:blank:]]+/, $deps) {
                    my $dep_params = App::Sqitch::Plan::Depend->parse(
                        $depstring,
                    ) or $raise_syntax_error->(__x(
                        '"{dep}" is not a valid dependency specification',
                        dep => $depstring,
                    ));
                    my $dep = App::Sqitch::Plan::Depend->new(
                        plan => $self,
                        %{ $dep_params },
                    );
                    if ($dep->conflicts) {
                        push @con => $dep;
                    } else {
                        push @req => $dep;
                    }
                }
                $params{requires}  = \@req;
                $params{conflicts} = \@con;
            }

            $tag_changes{ $params{name} } = $fh->input_line_number;
            push @curr_changes => $prev_change = App::Sqitch::Plan::Change->new(
                plan => $self,
                ( $prev_tag    ? ( since_tag => $prev_tag    ) : () ),
                ( $prev_change ? ( parent    => $prev_change ) : () ),
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
    push @changes => $self->check_changes(
        $pragmas{project},
        \%line_no_for,
        @curr_changes,
    ) if @curr_changes;

    return {
        changes => \@changes,
        lines   => \@lines,
        pragmas => \%pragmas,
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

sub check_changes {
    my ( $self, $proj ) = ( shift, shift );
    my $seen = ref $_[0] eq 'HASH' ? shift : {};

    my %position;
    my @invalid;

    my $i = 0;
    for my $change (@_) {
        my @bad;

        # XXX Ignoring conflicts for now.
        for my $dep ( $change->requires ) {
            # Ignore dependencies on other projects.
            if ($dep->got_project) {
                # Skip if parsed project name different from current project.
                next if $dep->project ne $proj;
            } else {
                # Skip if an ID was passed, is it could be internal or external.
                next if $dep->got_id;
            }
            my $key = $dep->key_name;

            # Skip it if it's a change from an earlier tag.
            if ($key =~ /.@/) {
                # Need to look it up before the tag.
                my ( $change, $tag ) = split /@/ => $key, 2;
                if ( my $tag_at = $seen->{"\@$tag"} ) {
                    if ( my $change_at = $seen->{$change}) {
                        next if $change_at < $tag_at;
                    }
                }
            } else {
                # Skip it if we've already seen it in the plan.
                next if exists $seen->{$key} || $position{$key};
            }

            # Hrm, unknown dependency.
            push @bad, $key;
        }
        $position{$change->name} = ++$i;
        push @invalid, [ $change->name => \@bad ] if @bad;
    }


    # Nothing bad, then go!
    return @_ unless @invalid;

    # Build up all of the error messages.
    my @errors;
    for my $bad (@invalid) {
        my $change = $bad->[0];
        my $max_delta = 0;
        for my $dep (@{ $bad->[1] }) {
            if ($change eq $dep) {
                push @errors => __x(
                    'Change "{change}" cannot require itself',
                    change => $change,
                );
            } elsif (my $pos = $position{ $dep }) {
                my $delta = $pos - $position{$change};
                $max_delta = $delta if $delta > $max_delta;
                push @errors => __xn(
                    'Change "{change}" planned {num} change before required change "{required}"',
                    'Change "{change}" planned {num} changes before required change "{required}"',
                    $delta,
                    change   => $change,
                    required => $dep,
                    num      => $delta,
                );
            } else {
                push @errors => __x(
                    'Unknown change "{required}" required by change "{change}"',
                    required => $dep,
                    change   => $change,
                );
            }
        }
        if ($max_delta) {
            # Suggest that the change be moved.
            # XXX Potentially offer to move it and rewrite the plan.
            $errors[-1] .= "\n    " .  __xn(
                'HINT: move "{change}" down {num} line in {plan}',
                'HINT: move "{change}" down {num} lines in {plan}',
                $max_delta,
                change => $change,
                num    => $max_delta,
                plan   => $self->sqitch->plan_file,
            );
        }
    }

    # Throw the exception with all of the errors.
    hurl plan => join(
        "\n  ",
        __n(
            'Dependency error detected:',
            'Dependency errors detected:',
            @errors
        ),
        @errors,
    );
}

sub open_script {
    my ( $self, $file ) = @_;
    return $file->open('<:encoding(UTF-8)') or hurl plan => __x(
        'Cannot open {file}: {error}',
        file  => $file,
        error => $!,
    );
}

sub syntax_version { shift->_plan->{pragmas}{syntax_version} };
sub lines          { shift->_lines->items }
sub changes        { shift->_changes->changes }
sub tags           { shift->_changes->tags }
sub count          { shift->_changes->count }
sub index_of       { shift->_changes->index_of(shift) }
sub get            { shift->_changes->get(shift) }
sub find           { shift->_changes->find(shift) }
sub first_index_of { shift->_changes->first_index_of(@_) }
sub change_at      { shift->_changes->change_at(shift) }
sub last_tagged_change { shift->_changes->last_tagged_change }

sub seek {
    my ( $self, $key ) = @_;
    my $index = $self->index_of($key);
    hurl plan => __x(
        'Cannot find change "{change}" in plan',
        change => $key,
    ) unless defined $index;
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
    $self->_changes->change_at( $pos );
}

sub peek {
    my $self = shift;
    $self->_changes->change_at( $self->position + 1 );
}

sub last {
    shift->_changes->change_at( -1 );
}

sub do {
    my ( $self, $code ) = @_;
    while ( local $_ = $self->next ) {
        return unless $code->($_);
    }
}

sub tag {
    my ( $self, %p ) = @_;
    ( my $name = $p{name} ) =~ s/^@//;
    $self->_is_valid(tag => $name);

    my $changes = $self->_changes;
    my $key   = "\@$name";

    hurl plan => __x(
        'Tag "{tag}" already exists',
        tag => $key
    ) if defined $changes->index_of($key);

    my $change = $changes->last_change or hurl plan => __x(
        'Cannot apply tag "{tag}" to a plan with no changes',
        tag => $key
    );

    my $tag = App::Sqitch::Plan::Tag->new(
        %p,
        plan   => $self,
        name   => $name,
        change => $change,
        rspace => $p{note} ? ' ' : '',
    );

    $change->add_tag($tag);
    $changes->index_tag( $changes->index_of( $change->id ), $tag );
    $self->_lines->append( $tag );
    return $tag;
}

sub _parse_deps {
    my ( $self, $p ) = @_;
    # Dependencies must be parsed into objects.
    $p->{requires} = [ map {
        my $p = App::Sqitch::Plan::Depend->parse($_) // hurl plan => __x(
            '"{dep}" is not a valid dependency specification',
            dep => $_,
        );
        App::Sqitch::Plan::Depend->new(
            %{ $p },
            plan      => $self,
            conflicts => 0,
        );
    } @{ $p->{requires} } ] if $p->{requires};

    $p->{conflicts} = [ map {
        my $p = App::Sqitch::Plan::Depend->parse("!$_") // hurl plan => __x(
            '"{dep}" is not a valid dependency specification',
            dep => $_,
        );
        App::Sqitch::Plan::Depend->new(
            %{ $p },
            plan      => $self,
            conflicts => 1,
        );
    } @{ $p->{conflicts} } ] if $p->{conflicts};
}

sub add {
    my ( $self, %p ) = @_;
    $self->_is_valid(change => $p{name});
    my $changes = $self->_changes;

    if ( defined( my $idx = $changes->index_of( $p{name} . '@HEAD' ) ) ) {
        my $tag_idx = $changes->index_of_last_tagged;
        hurl plan => __x(
            qq{Change "{change}" already exists.\n}
            . 'Use "sqitch rework" to copy and rework it',
            change => $p{name},
        );
    }

    $self->_parse_deps(\%p);

    $p{rspace} //= ' ' if $p{note};
    my $change = App::Sqitch::Plan::Change->new( %p, plan => $self );

    # Make sure dependencies are valid.
    $self->_check_dependencies( $change, 'add' );

    # We good. Append a blank line if the previous change has a tag.
    if ( $changes->count ) {
        my $prev = $changes->change_at( $changes->count - 1 );
        if ( $prev->tags ) {
            $self->_lines->append(
                App::Sqitch::Plan::Blank->new( plan => $self )
            );
        }
    }

    # Append the change and return.
    $changes->append( $change );
    $self->_lines->append( $change );
    return $change;
}

sub rework {
    my ( $self, %p ) = @_;
    my $changes = $self->_changes;
    my $idx   = $changes->index_of( $p{name} . '@HEAD') // hurl plan => __x(
        qq{Change "{change}" does not exist.\n}
        . 'Use "sqitch add {change}" to add it to the plan',
        change => $p{name},
    );

    my $tag_idx = $changes->index_of_last_tagged;
    hurl plan => __x(
        qq{Cannot rework "{change}" without an intervening tag.\n}
        . 'Use "sqitch tag" to create a tag and try again',
        change => $p{name},
    ) if !defined $tag_idx || $tag_idx < $idx;

    $self->_parse_deps(\%p);

    my ($tag) = $changes->change_at($tag_idx)->tags;
    unshift @{ $p{requires} ||= [] } => App::Sqitch::Plan::Depend->new(
        plan    => $self,
        change  => $p{name},
        tag     => $tag->name,
    );

    my $orig = $changes->change_at($idx);
    my $new  = App::Sqitch::Plan::Change->new( %p, plan => $self );

    # Make sure dependencies are valid.
    $self->_check_dependencies( $new, 'rework' );

    # We good.
    $orig->suffix( $tag->format_name );
    $changes->append( $new );
    $self->_lines->append( $new );
    return $new;
}

sub _check_dependencies {
    my ( $self, $change, $action ) = @_;
    my $changes = $self->_changes;
    my $project = $self->project;
    for my $req ( $change->requires ) {
        next if $req->project ne $project;
        $req = $req->key_name;
        next if defined $changes->index_of($req =~ /@/ ? $req : $req . '@HEAD');
        my $name = $change->name;
        if ($action eq 'add') {
            hurl plan => __x(
                'Cannot add change "{change}": requires unknown change "{req}"',
                change => $name,
                req    => $req,
            );
        } else {
            hurl plan => __x(
                'Cannot rework change "{change}": requires unknown change "{req}"',
                change => $name,
                req    => $req,
            );
        }
    }
    return $self;
}

sub _is_valid {
    my ( $self, $type, $name ) = @_;
    hurl plan => __x(
        '"{name}" is a reserved name',
        name => $name
    ) if exists $reserved{$name};
    hurl plan => __x(
        '"{name}" is invalid because it could be confused with a SHA1 ID',
        name => $name,
    ) if $name =~ /^[0-9a-f]{40}/;

    unless ($name =~ /\A$name_re\z/) {
        if ($type eq 'change') {
            hurl plan => __x(
                qq{"{name}" is invalid: changes must not begin with punctuation, }
                . 'contain "@", ":", or "#", or end in punctuation or digits following punctuation',
                name => $name,
            );
        } else {
            hurl plan => __x(
                qq{"{name}" is invalid: tags must not begin with punctuation, }
                . 'contain "@", ":", or "#", or end in punctuation or digits following punctuation',
                name => $name,
            );
        }
    }
}

sub write_to {
    my ( $self, $file, $from, $to ) = @_;

    my @lines = $self->lines;

    if (defined $from || defined $to) {
        my $lines = $self->_lines;

        # Where are the pragmas?
        my $head_ends_at = do {
            my $i = 0;
            while ( my $line = $lines[$i] ) {
                last if $line->isa('App::Sqitch::Plan::Blank')
                     && !length $line->note;
                ++$i;
            }
            $i;
        };

        # Where do we start with the changes?
        my $from_idx = defined $from ? do {
            my $change = $self->find($from // '@ROOT') //  hurl plan => __x(
                'Cannot find change {change}',
                change => $from,
            );
            $lines->index_of($change);
        } : $head_ends_at + 1;

        # Where do we end up?
        my $to_idx = defined $to ? do {
            my $change = $self->find( $to // '@HEAD' ) // hurl plan => __x(
                'Cannot find change {change}',
                change => $to,
            );

            # Include any subsequent tags.
            if (my @tags = $change->tags) {
                $change = $tags[-1];
            }
            $lines->index_of($change);
        } : $#lines;

        # Collect the lines to write.
        @lines = (
            @lines[ 0         .. $head_ends_at ],
            @lines[ $from_idx .. $to_idx       ],
        );
    }

    my $fh = $file->open('>:encoding(UTF-8)') or hurl plan => __x(
        'Cannot open {file}: {error}',
        file  => $file,
        error => $!
    );
    $fh->say($_->as_string) for @lines;
    $fh->close or hurl plan => __x(
        '"Error closing {file}: {error}',
        file => $file,
        error => $!,
    );
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

=head2 Class Methods

=head3 C<name_regex>

  die "$this has no name" unless $this =~ App::Sqitch::Plan->name_regex;

Returns a regular expression that matches names. Note that it is not anchored,
so if you need to make sure that a string is a valid name and nothing else,
you will need to anchor it yourself, like so:

    my $name_re = App::Sqitch::Plan->name_regex;
    die "$this is not a valid name" if $this !~ /\A$name_re\z/;

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

=head3 C<project>

  my $project = $plan->project;

Returns the name of the project as set via the C<%project> pragma in the plan
file.

=head3 C<uri>

  my $uri = $plan->uri;

Returns the URI for the project as set via the C<%uri> pragma, which is
optional. If it is not present, C<undef> will be returned.

=head3 C<syntax_version>

  my $syntax_version = $plan->syntax_version;

Returns the plan syntax version, which is always the latest version.

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
  $plan->write_to($file, $from, $to);

Write the plan to the named file, including notes and white space from the
original plan file. If C<from> and/or C<$to> are provided, the plan will be
written only with the pragmas headers and the lines between those specified
changes.

=head3 C<open_script>

  my $file_handle = $plan->open_script( $change->deploy_file );

Opens the script file passed to it and returns a file handle for reading. The
script file must be encoded in UTF-8.

=head3 C<load>

  my $plan_data = $plan->load;

Loads the plan data. Called internally, not meant to be called directly, as it
parses the plan file and deploy scripts every time it's called. If you want
the all of the changes, call C<changes()> instead.

=head3 C<check_changes>

  @changes = $plan->check_changes( $project, @changes );
  @changes = $plan->check_changes( $project, { '@foo' => 1 }, @changes );

Checks a list of changes to validate their depenencies and returns them. If
the second argument is a hash reference, its keys should be previously-seen
change and tag names that can be assumed to be satisfied requirements for the
succeeding changes.

=head3 C<tag>

  $plan->tag('whee');

Tags the most recent change in the plan. Exits with a fatal error if the tag
already exists in the plan.

=head3 C<add>

  $plan->add( name => 'whatevs' );
  $plan->add(
      name      => 'widgets',
      requires  => [qw(foo bar)],
      conflicts => [qw(dr_evil)],
  );

Adds a change to the plan. The supported parameters are the same as those
passed to the L<App::Sqitch::Plan::Change> constructor. Exits with a fatal
error if the change already exists, or if the any of the dependencies are
unknown.

=head3 C<rework>

  $plan->rework( 'whatevs' );
  $plan->rework( 'widgets', [qw(foo bar)], [qw(dr_evil)] );

Reworks an existing change. Said change must already exist in the plan and be
tagged or have a tag following it or an exception will be thrown. The previous
occurrence of the change will have the suffix of the most recent tag added to
it, and a new tag instance will be added to the list.

=head1 Plan File

A plan file describes the deployment changes to be run against a database, and
is typically maintained using the L<C<add>|sqitch-add> and
L<C<rework>|sqitch-rework> commands. Its contents must be plain text encoded
as UTF-8. Each line of a plan file may be one of four things:

=over

=item *

A blank line. May include any amount of white space, which will be ignored.

=item * A Pragma

Begins with a C<%>, followed by a pragma name, optionally followed by C<=> and
a value. Currently, the only pragma recognized by Sqitch is C<syntax-version>.

=item * A change.

A named change change as defined in L<sqitchchanges>. A change may then also
contain a space-delimited list of dependencies, which are the names of other
changes or tags prefixed with a colon (C<:>) for required changes or with an
exclamation point (C<!>) for conflicting changes.

Changes with a leading C<-> are slated to be reverted, while changes with no
character or a leading C<+> are to be deployed.

=item * A tag.

A named deployment tag, generally corresponding to a release name. Begins with
a C<@>, followed by one or more non-whitespace characters, excluding "@", ":",
and "#". The first and last characters must not be punctuation characters.

=item * A note.

Begins with a C<#> and goes to the end of the line. Preceding white space is
ignored. May appear on a line after a pragma, change, or tag.

=back

Here's an example of a plan file with a single deploy change and tag:

 %syntax-version=1.0.0
 +users_table
 @alpha

There may, of course, be any number of tags and changes. Here's an expansion:

 %syntax-version=1.0.0
 +users_table
 +insert_user
 +update_user
 +delete_user
 @root
 @alpha

Here we have four changes -- "users_table", "insert_user", "update_user", and
"delete_user" -- followed by two tags: "@root" and "@alpha".

Most plans will have many changes and tags. Here's a longer example with three
tagged deployment points, as well as a change that is deployed and later
reverted:

 %syntax-version=1.0.0
 +users_table
 +insert_user
 +update_user
 +delete_user
 +dr_evil
 @root
 @alpha

 +widgets_table
 +list_widgets
 @beta

 -dr_evil
 +ftw
 @gamma

Using this plan, to deploy to the "beta" tag, all of the changes up to the
"@root" and "@alpha" tags must be deployed, as must changes listed before the
"@beta" tag. To then deploy to the "@gamma" tag, the "dr_evil" change must be
reverted and the "ftw" change must be deployed. If you then choose to revert
to "@alpha", then the "ftw" change will be reverted, the "dr_evil" change
re-deployed, and the "@gamma" tag removed; then "list_widgets" must be
reverted and the associated "@beta" tag removed, then the "widgets_table"
change must be reverted.

Changes can only be repeated if one or more tags intervene. This allows Sqitch
to distinguish between them. An example:

 %syntax-version=1.0.0
 +users_table
 @alpha

 +add_widget
 +widgets_table
 @beta

 +add_user
 @gamma

 +widgets_created_at
 @delta

 +add_widget

Note that the "add_widget" change is repeated after the "@beta" tag, and at
the end. Sqitch will notice the repetition when it parses this file, and allow
it, because at least one tag "@beta" appears between the instances of
"add_widget". When deploying, Sqitch will fetch the instance of the deploy
script as of the "@delta" tag and apply it as the first change, and then, when
it gets to the last change, retrieve the current instance of the deploy
script. How does it find such files? The first instances files will either be
named F<add_widget@delta.sql> or (soon) findable in the VCS history as of a
VCS "delta" tag.

=head2 Grammar

Here is the EBNF Grammar for the plan file:

  plan-file    = { <pragma> | <change-line> | <tag-line> | <note-line> | <blank-line> }* ;

  blank-line   = [ <blanks> ] <eol>;
  note-line    = <note> ;
  change-line  = <name> [ "[" { <requires> | <conflicts> } "]" ] ( <eol> | <note> ) ;
  tag-line     = <tag> ( <eol> | <note> ) ;
  pragma       = "%" [ <blanks> ] <name> [ <blanks> ] = [ <blanks> ] <value> ( <eol> | <note> ) ;

  tag          = "@" <name> ;
  requires     = <name> ;
  conflicts    = "!" <name> ;
  name         = <non-punct> [ [ ? non-blank and not "@", ":", or "#" characters ? ] <non-punct> ] ;
  non-punct    = ? non-punctuation, non-blank character ? ;
  value        = ? non-EOL or "#" characters ?

  note         = [ <blanks> ] "#" [ <string> ] <EOL> ;
  eol          = [ <blanks> ] <EOL> ;

  blanks       = ? blank characters ? ;
  string       = ? non-EOL characters ? ;

And written as regular expressions:

  my $eol          = qr/[[:blank:]]*$/
  my $note         = qr/(?:[[:blank:]]+)?[#].+$/;
  my $punct        = q{-!"#$%&'()*+,./:;<=>?@[\\]^`{|}~};
  my $name         = qr/[^$punct[:blank:]](?:(?:[^[:space:]:#@]+)?[^$punct[:blank:]])?/;
  my $tag          = qr/[@]$name/;
  my $requires     = qr/$name/;
  my conflicts     = qr/[!]$name/;
  my $tag_line     = qr/^$tag(?:$note|$eol)/;
  my $change_line  = qr/^$name(?:[[](?:$requires|$conflicts)+[]])?(?:$note|$eol)/;
  my $note_line    = qr/^$note/;
  my $pragma       = qr/^][[:blank:]]*[%][[:blank:]]*$name[[:blank:]]*=[[:blank:]].+?(?:$note|$eol)$/;
  my $blank_line   = qr/^$eol/;
  my $plan         = qr/(?:$pragma|$change_line|$tag_line|$note_line|$blank_line)+/ms;

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
