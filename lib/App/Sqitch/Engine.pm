package App::Sqitch::Engine;

use 5.010;
use Moo;
use strict;
use utf8;
use Try::Tiny;
use Locale::TextDomain qw(App-Sqitch);
use Path::Class qw(file);
use App::Sqitch::X qw(hurl);
use List::Util qw(first max);
use URI::db 0.19;
use App::Sqitch::Types qw(Str Int Sqitch Plan Bool HashRef URI Maybe Target);
use namespace::autoclean;
use constant registry_release => '1.1';

our $VERSION = '0.9998';

has sqitch => (
    is       => 'ro',
    isa      => Sqitch,
    required => 1,
    weak_ref => 1,
);

has target => (
    is       => 'ro',
    isa      => Target,
    required => 1,
    weak_ref => 1,
    handles => {
        uri         => 'uri',
        client      => 'client',
        registry    => 'registry',
        destination => 'name',
    }
);

has username => (
    is      => 'ro',
    isa     => Maybe[Str],
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->target->username || $self->_def_user
    },
);

has password => (
    is      => 'ro',
    isa     => Maybe[Str],
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->target->password || $self->_def_pass
    },
);

sub _def_user { }
sub _def_pass { }

sub registry_destination { shift->destination }

has start_at => (
    is  => 'rw',
    isa => Str
);

has no_prompt => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

has prompt_accept => (
    is      => 'rw',
    isa     => Bool,
    default => 1,
);

has log_only => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

has with_verify => (
    is      => 'rw',
    isa     => Bool,
    default => 0,
);

has max_name_length => (
    is      => 'rw',
    isa     => Int,
    default => 0,
    lazy    => 1,
    default => sub {
        my $plan = shift->plan;
        max map {
            length $_->format_name_with_tags
        } $plan->changes;
    },
);

has plan => (
    is       => 'rw',
    isa      => Plan,
    lazy     => 1,
    default  => sub { shift->target->plan }
);

has _variables => (
    is      => 'rw',
    isa     => HashRef[Str],
    default => sub { {} },
);

sub variables       { %{ shift->_variables }       }
sub set_variables   {    shift->_variables({ @_ }) }
sub clear_variables { %{ shift->_variables } = ()  }

sub default_registry { 'sqitch' }

sub load {
    my ( $class, $p ) = @_;

    # We should have an engine param.
    my $target = $p->{target} or hurl 'Missing "target" parameter to load()';

    # Load the engine class.
    my $ekey = $target->engine_key or hurl engine => __(
        'No engine specified; use --engine or set core.engine'
    );

    my $pkg = __PACKAGE__ . '::' . $target->engine_key;
    eval "require $pkg" or hurl "Unable to load $pkg";
    return $pkg->new( $p );
}

sub driver { shift->key }

sub key {
    my $class = ref $_[0] || shift;
    hurl engine => __ 'No engine specified; use --engine or set core.engine'
        if $class eq __PACKAGE__;
    my $pkg = quotemeta __PACKAGE__;
    $class =~ s/^$pkg\:://;
    return $class;
}

sub name { shift->key }

sub config_vars {
    return (
        target   => 'any',
        registry => 'any',
        client   => 'any'
    );
}

sub use_driver {
    my $self = shift;
    my $driver = $self->driver;
    eval "use $driver";
    hurl $self->key => __x(
        '{driver} required to manage {engine}',
        driver  => $driver,
        engine  => $self->name,
    ) if $@;
    return $self;
}

sub deploy {
    my ( $self, $to, $mode ) = @_;
    my $sqitch   = $self->sqitch;
    my $plan     = $self->_sync_plan;
    my $to_index = $plan->count - 1;

    hurl plan => __ 'Nothing to deploy (empty plan)' if $to_index < 0;

    if (defined $to) {
        $to_index = $plan->index_of($to) // hurl plan => __x(
            'Unknown change: "{change}"',
            change => $to,
        );

        # Just return if there is nothing to do.
        if ($to_index == $plan->position) {
            $sqitch->info(__x(
                'Nothing to deploy (already at "{change}")',
                change => $to
            ));
            return $self;
        }
    }

    if ($plan->position == $to_index) {
        # We are up-to-date.
        $sqitch->info( __ 'Nothing to deploy (up-to-date)' );
        return $self;

    } elsif ($plan->position == -1) {
        # Initialize or upgrade the database, if necessary.
        if ($self->initialized) {
            $self->upgrade_registry;
        } else {
            $sqitch->info(__x(
                'Adding registry tables to {destination}',
                destination => $self->registry_destination,
            ));
            $self->initialize;
        }
        $self->register_project;

    } else {
        # Make sure that $to_index is greater than the current point.
        hurl deploy => __ 'Cannot deploy to an earlier change; use "revert" instead'
            if $to_index < $plan->position;
        # Upgrade database if it needs it.
        $self->upgrade_registry;
    }

    $sqitch->info(
        defined $to ? __x(
            'Deploying changes through {change} to {destination}',
            change      => $plan->change_at($to_index)->format_name_with_tags,
            destination => $self->destination,
        ) : __x(
            'Deploying changes to {destination}',
            destination => $self->destination,
        )
    );

    # Check that all dependencies will be satisfied.
    $self->check_deploy_dependencies($plan, $to_index);

    # Do it!
    $mode ||= 'all';
    my $meth = $mode eq 'change' ? '_deploy_by_change'
             : $mode eq 'tag'  ? '_deploy_by_tag'
             : $mode eq 'all'  ? '_deploy_all'
             : hurl deploy => __x 'Unknown deployment mode: "{mode}"', mode => $mode;
    ;

    $self->max_name_length(
        max map {
            length $_->format_name_with_tags
        } ($plan->changes)[$plan->position + 1..$to_index]
    );

    $self->$meth( $plan, $to_index );
}

sub revert {
    my ( $self, $to ) = @_;
    $self->_check_registry;
    my $sqitch = $self->sqitch;
    my $plan   = $self->plan;

    my @changes;

    if (defined $to) {
        my ($change) = $self->_load_changes(
            $self->change_for_key($to)
        ) or do {
            # Not deployed. Is it in the plan?
            if ( $plan->find($to) ) {
                # Known but not deployed.
                hurl revert => __x(
                    'Change not deployed: "{change}"',
                    change => $to
                );
            }
            # Never heard of it.
            hurl revert => __x(
                'Unknown change: "{change}"',
                change => $to,
            );
        };

        @changes = $self->deployed_changes_since(
            $self->_load_changes($change)
        ) or do {
            $sqitch->info(__x(
                'No changes deployed since: "{change}"',
                change => $to,
            ));
            return $self;
        };

        if ($self->no_prompt) {
            $sqitch->info(__x(
                'Reverting changes to {change} from {destination}',
                change      => $change->format_name_with_tags,
                destination => $self->destination,
            ));
        } else {
            hurl {
                ident   => 'revert:confirm',
                message => __ 'Nothing reverted',
                exitval => 1,
            } unless $sqitch->ask_y_n(__x(
                'Revert changes to {change} from {destination}?',
                change      => $change->format_name_with_tags,
                destination => $self->destination,
            ), $self->prompt_accept ? 'Yes' : 'No' );
        }

    } else {
        @changes = $self->deployed_changes or do {
            $sqitch->info(__ 'Nothing to revert (nothing deployed)');
            return $self;
        };

        if ($self->no_prompt) {
            $sqitch->info(__x(
                'Reverting all changes from {destination}',
                destination => $self->destination,
            ));
        } else {
            hurl {
                ident   => 'revert',
                message => __ 'Nothing reverted',
                exitval => 1,
            } unless $sqitch->ask_y_n(__x(
                'Revert all changes from {destination}?',
                destination => $self->destination,
            ), $self->prompt_accept ? 'Yes' : 'No' );
        }
    }

    # Make change objects and check that all dependencies will be satisfied.
    @changes = reverse $self->_load_changes( @changes );
    $self->check_revert_dependencies(@changes);

    # Do we want to support modes, where failures would re-deploy to previous
    # tag or all the way back to the starting point? This would be very much
    # like deploy() mode. I'm thinking not, as a failure on a revert is not
    # something you generally want to recover from by deploying back to where
    # you started. But maybe I'm wrong?
    $self->max_name_length(
        max map { length $_->format_name_with_tags } @changes
    );
    $self->revert_change($_) for @changes;

    return $self;
}

sub verify {
    my ( $self, $from, $to ) = @_;
    $self->_check_registry;
    my $sqitch   = $self->sqitch;
    my $plan     = $self->plan;
    my @changes  = $self->_load_changes( $self->deployed_changes );

    $sqitch->info(__x(
        'Verifying {destination}',
        destination => $self->destination,
    ));

    if (!@changes) {
        my $msg = $plan->count
            ? __ 'No changes deployed'
            : __ 'Nothing to verify (no planned or deployed changes)';
        $sqitch->info($msg);
        return $self;
    }

    if ($plan->count == 0) {
        # Oy, there are deployed changes, but not planned!
        hurl verify => __ 'There are deployed changes, but none planned!';
    }

    # Figure out where to start and end relative to the plan.
    my $from_idx = defined $from
        ? $self->_trim_to('verify', $from, \@changes)
        : 0;

    my $to_idx = defined $to ? $self->_trim_to('verify', $to, \@changes, 1) : do {
        if (my $id = $self->latest_change_id) {
            $plan->index_of( $id );
        }
    } // $plan->count - 1;

    # Run the verify tests.
    if ( my $count = $self->_verify_changes($from_idx, $to_idx, !$to, @changes) ) {
        # Emit a quick report.
        # XXX Consider coloring red.
        my $num_changes = 1 + $to_idx - $from_idx;
        $num_changes = @changes if @changes > $num_changes;
        my $msg = __ 'Verify Summary Report';
        $sqitch->emit("\n", $msg);
        $sqitch->emit('-' x length $msg);
        $sqitch->emit(__x 'Changes: {number}', number => $num_changes );
        $sqitch->emit(__x 'Errors:  {number}', number => $count );
        hurl verify => __ 'Verify failed';
    }

    # Success!
    # XXX Consider coloring green.
    $sqitch->emit(__ 'Verify successful');

    return $self;
}

sub _trim_to {
    my ( $self, $ident, $key, $changes, $pop ) = @_;
    my $sqitch = $self->sqitch;
    my $plan   = $self->plan;

    # Find the to change in the database.
    my $to_id = $self->change_id_for_key( $key ) || hurl $ident => (
        $plan->contains( $key ) ? __x(
            'Change "{change}" has not been deployed',
            change => $key,
        ) : __x(
            'Cannot find "{change}" in the database or the plan',
            change => $key,
        )
    );

    # Find the change in the plan.
    my $to_idx = $plan->index_of( $to_id ) // hurl $ident => __x(
        'Change "{change}" is deployed, but not planned',
        change => $key,
    );

    # Pop or shift changes till we find the change we want.
    if ($pop) {
        pop @{ $changes }   while $changes->[-1]->id ne $to_id;
    } else {
        shift @{ $changes } while $changes->[0]->id  ne $to_id;
    }

    # We good.
    return $to_idx;
}

sub _verify_changes {
    my $self     = shift;
    my $from_idx = shift;
    my $to_idx   = shift;
    my $pending  = shift;
    my $sqitch   = $self->sqitch;
    my $plan     = $self->plan;
    my $errcount = 0;
    my $i        = -1;
    my @seen;

    my $max_name_len = max map {
        length $_->format_name_with_tags
    } @_, map { $plan->change_at($_) } $from_idx..$to_idx;

    for my $change (@_) {
        $i++;
        my $errs     = 0;
        my $reworked = 0;
        my $name     = $change->format_name_with_tags;
        $sqitch->emit_literal(
            "  * $name ..",
            '.' x ($max_name_len - length $name), ' '
        );

        my $plan_index = $plan->index_of( $change->id );
        if (defined $plan_index) {
            push @seen => $plan_index;
            if ( $plan_index != ($from_idx + $i) ) {
                $sqitch->comment(__ 'Out of order');
                $errs++;
            }
            # Is it reworked?
            $reworked = $plan->change_at($plan_index)->is_reworked;
        } else {
            $sqitch->comment(__ 'Not present in the plan');
            $errs++;
        }

        # Run the verify script.
        try { $self->verify_change( $change ) } catch {
            $sqitch->comment(eval { $_->message } // $_);
            $errs++;
        } unless $reworked;

        # Emit pass/fail and add to the total error count.
        $sqitch->emit( $errs ? __ 'not ok' : __ 'ok' );
        $errcount += $errs;
    }

    # List any undeployed changes.
    for my $idx ($from_idx..$to_idx) {
        next if defined first { $_ == $idx } @seen;
        my $change = $plan->change_at( $idx );
        my $name   = $change->format_name_with_tags;
        $sqitch->emit_literal(
            "  * $name ..",
            '.' x ($max_name_len - length $name), ' ',
            __ 'not ok', ' '
        );
        $sqitch->comment(__ 'Not deployed');
        $errcount++;
    }

    # List any pending changes.
    if ($pending && $to_idx < ($plan->count - 1)) {
        if (my @pending = map {
            $plan->change_at($_)
        } ($to_idx + 1)..($plan->count - 1) ) {
            $sqitch->emit(__n(
                'Undeployed change:',
                'Undeployed changes:',
                @pending,
            ));

            $sqitch->emit( '  * ', $_->format_name_with_tags ) for @pending;
        }
    }

    return $errcount;
}

sub verify_change {
    my ( $self, $change ) = @_;
    my $file = $change->verify_file;
    if (-e $file) {
        return try { $self->run_verify($file) }
        catch {
            hurl {
                ident => 'verify',
                previous_exception => $_,
                message => __x(
                    'Verify script "{script}" failed.',
                    script => $file,
                ),
            };
        };
    }

    # The file does not exist. Complain, but don't die.
    $self->sqitch->vent(__x(
        'Verify script {file} does not exist',
        file => $file,
    ));

    return $self;
}

sub run_deploy  { shift->run_file(@_) }
sub run_revert  { shift->run_file(@_) }
sub run_verify  { shift->run_file(@_) }
sub run_upgrade { shift->run_file(@_) }

sub check_deploy_dependencies {
    my ( $self, $plan, $to_index ) = @_;
    my $from_index = $plan->position + 1;
    $to_index    //= $plan->count - 1;
    my @changes = map { $plan->change_at($_) } $from_index..$to_index;
    my (%seen, @conflicts, @required);

    for my $change (@changes) {
        # Check for conflicts.
        push @conflicts => grep {
            $seen{ $_->id // '' } || $self->change_id_for_depend($_)
        } $change->conflicts;

        # Check for prerequisites.
        push @required => grep { !$_->resolved_id(do {
            if ( my $req = $seen{ $_->id // '' } ) {
                $req->id;
            } else {
                $self->change_id_for_depend($_);
            }
        }) } $change->requires;
        $seen{ $change->id } = $change;
    }

    if (@conflicts or @required) {
        require List::MoreUtils;
        # Dependencies not satisfied. Put together the error messages.
        my @msg;
        push @msg, __nx(
            'Conflicts with previously deployed change: {changes}',
            'Conflicts with previously deployed changes: {changes}',
            scalar @conflicts,
            changes => join ' ', map { $_->as_string } @conflicts,
        ) if @conflicts = List::MoreUtils::uniq(@conflicts);

        push @msg, __nx(
            'Missing required change: {changes}',
            'Missing required changes: {changes}',
            scalar @required,
            changes => join ' ', map { $_->as_string } @required,
        ) if @required = List::MoreUtils::uniq(@required);

        hurl deploy => join "\n" => @msg;
    }

    # Make sure nothing isn't already deployed.
    if ( my @ids = $self->are_deployed_changes(@changes) ) {
        hurl deploy => __nx(
            'Change "{changes}" has already been deployed',
            'Changes have already been deployed: {changes}',
            scalar @ids,
            changes => join ' ', map { $seen{$_} } @ids
        );
    }

    return $self;
}

sub check_revert_dependencies {
    my $self = shift;
    my $proj = $self->plan->project;
    my (%seen, @msg);

    for my $change (@_) {
        $seen{ $change->id } = 1;
        my @requiring = grep {
            !$seen{ $_->{change_id} }
        } $self->changes_requiring_change($change) or next;

        # XXX Include change_id in the output?
        push @msg => __nx(
            'Change "{change}" required by currently deployed change: {changes}',
            'Change "{change}" required by currently deployed changes: {changes}',
            scalar @requiring,
            change  => $change->format_name_with_tags,
            changes => join ' ', map {
                ($_->{project} eq $proj ? '' : "$_->{project}:" )
                . $_->{change}
                . ($_->{asof_tag} // '')
            } @requiring
        );
    }

    hurl revert => join "\n", @msg if @msg;

    # XXX Should we make sure that they are all deployed before trying to
    # revert them?

    return $self;
}

sub change_id_for_depend {
    my ( $self, $dep ) = @_;
    hurl engine =>  __x(
        'Invalid dependency: {dependency}',
        dependency => $dep->as_string,
    ) unless defined $dep->id
          || defined $dep->change
          || defined $dep->tag;

    return $self->change_id_for(
        change_id => $dep->id,
        change    => $dep->change,
        tag       => $dep->tag,
        project   => $dep->project,
    );
}

sub _params_for_key {
    my ( $self, $key ) = @_;
    my $offset = App::Sqitch::Plan::ChangeList::_offset $key;
    my ( $cname, $tag ) = split /@/ => $key, 2;

    my @off = ( offset => $offset );
    return ( @off, change => $cname, tag => $tag ) if $tag;
    return ( @off, change_id => $cname ) if $cname =~ /^[0-9a-f]{40}$/;
    return ( @off, tag => $cname ) if $cname eq 'HEAD' || $cname eq 'ROOT';
    return ( @off, change => $cname );
}

sub change_id_for_key {
    my $self = shift;
    return $self->find_change_id( $self->_params_for_key(shift) );
}

sub find_change_id {
    my ( $self, %p ) = @_;

    # Find the change ID or return undef.
    my $change_id = $self->change_id_for(
        change_id => $p{change_id},
        change    => $p{change},
        tag       => $p{tag},
        project   => $p{project} || $self->plan->project,
    ) // return;

    # Return relative to the offset.
    return $self->change_id_offset_from_id($change_id, $p{offset});
}

sub change_for_key {
    my $self = shift;
    return $self->find_change( $self->_params_for_key(shift) );
}

sub find_change {
    my ( $self, %p ) = @_;

    # Find the change ID or return undef.
    my $change_id = $self->change_id_for(
        change_id => $p{change_id},
        change    => $p{change},
        tag       => $p{tag},
        project   => $p{project} || $self->plan->project,
    ) // return;

    # Return relative to the offset.
    return $self->change_offset_from_id($change_id, $p{offset});
}

sub _load_changes {
    my $self = shift;
    my $plan = $self->plan;
    my (@changes, %seen);
    my %rework_tags_for;
    for my $params (@_) {
        next unless $params;
        my $tags = $params->{tags} || [];
        my $c = App::Sqitch::Plan::Change->new(%{ $params }, plan => $plan );

        # Add tags.
        $c->add_tag(
            App::Sqitch::Plan::Tag->new(name => $_, plan => $plan, change => $c )
        ) for map { s/^@//; $_ } @{ $tags };

        if ( defined ( my $prev_idx = $seen{ $params->{name} } ) ) {
            # It's reworked; grab all subsequent tags up to but not including
            # the reworking change to the reworked change.
            my $ctags = $rework_tags_for{ $prev_idx } ||= [];
            my $i;
            for my $x ($prev_idx..$#changes) {
                my $rtags = $ctags->[$i++] ||= [];
                my %s = map { $_->name => 1 } @{ $rtags };
                push @{ $rtags } => grep { !$s{$_->name} } $changes[$x]->tags;
            }
        }

        if ( defined ( my $reworked_idx = eval {
            $plan->first_index_of( @{ $params }{qw(name id)} )
        } ) ) {
            # The plan has it reworked later; grab all tags from this change
            # up to but not including the reworked change.
            my $ctags = $rework_tags_for{ $#changes + 1 } ||= [];
            my $idx = $plan->index_of($params->{id});
            my $i;
            for my $x ($idx..$reworked_idx - 1) {
                my $c = $plan->change_at($x);
                my $rtags = $ctags->[$i++] ||= [];
                push @{ $rtags } => $plan->change_at($x)->tags;
            }
        }

        push @changes => $c;
        $seen{ $params->{name} } = $#changes;
    }

    # Associate all rework tags in reverse order. Tags fetched from the plan
    # have priority over tags fetched from the database.
    while (my ($idx, $tags) = each %rework_tags_for) {
        my %seen;
        $changes[$idx]->add_rework_tags(
            grep { !$seen{$_->name}++ }
            map  { @{ $_ } } reverse @{ $tags }
        );
    }

    return @changes;
}

sub _handle_lookup_index {
    my ( $self, $change, $ids ) = @_;

    # Return if 0 or 1 ID.
    return $ids->[0] if @{ $ids } <= 1;

    # Too many found! Let the user know.
    my $sqitch = $self->sqitch;
    $sqitch->vent(__x(
        'Change "{change}" is ambiguous. Please specify a tag-qualified change:',
        change => $change,
    ));

    # Lookup, emit reverse-chron list of tag-qualified changes, and die.
    my $plan = $self->plan;
    for my $id ( reverse @{ $ids } ) {
        # Look in the plan, first.
        if ( my $change = $plan->find($id) ) {
            $self->sqitch->vent( '  * ', $change->format_tag_qualified_name )
        } else {
            # Look it up in the database.
            $self->sqitch->vent( '  * ', $self->name_for_change_id($id) // '' )
        }
    }
    hurl engine => __ 'Change Lookup Failed';
}

sub _deploy_by_change {
    my ( $self, $plan, $to_index ) = @_;

    # Just deploy each change. If any fails, we just stop.
    while ($plan->position < $to_index) {
        $self->deploy_change($plan->next);
    }

    return $self;
}

sub _rollback {
    my ($self, $tagged) = (shift, shift);
    my $sqitch = $self->sqitch;

    if (my @run = reverse @_) {
        $tagged = $tagged ? $tagged->format_name_with_tags : $self->start_at;
        $sqitch->vent(
            $tagged ? __x('Reverting to {change}', change => $tagged)
                    : __ 'Reverting all changes'
        );

        try {
            $self->revert_change($_) for @run;
        } catch {
            # Sucks when this happens.
            $sqitch->vent(eval { $_->message } // $_);
            $sqitch->vent(__ 'The schema will need to be manually repaired');
        };
    }

    hurl deploy => __ 'Deploy failed';
}

sub _deploy_by_tag {
    my ( $self, $plan, $to_index ) = @_;

    my ($last_tagged, @run);
    try {
        while ($plan->position < $to_index) {
            my $change = $plan->next;
            $self->deploy_change($change);
            push @run => $change;
            if ($change->tags) {
                @run = ();
                $last_tagged = $change;
            }
        }
    } catch {
        if (my $ident = eval { $_->ident }) {
            $self->sqitch->vent($_->message) unless $ident eq 'private'
        } else {
            $self->sqitch->vent($_);
        }
        $self->_rollback($last_tagged, @run);
    };

    return $self;
}

sub _deploy_all {
    my ( $self, $plan, $to_index ) = @_;

    my @run;
    try {
        while ($plan->position < $to_index) {
            my $change = $plan->next;
            $self->deploy_change($change);
            push @run => $change;
        }
    } catch {
        if (my $ident = eval { $_->ident }) {
            $self->sqitch->vent($_->message) unless $ident eq 'private'
        } else {
            $self->sqitch->vent($_);
        }
        $self->_rollback(undef, @run);
    };

    return $self;
}

sub _sync_plan {
    my $self = shift;
    my $plan = $self->plan;

    if (my $state = $self->current_state) {
        my $idx = $plan->index_of($state->{change_id}) // hurl plan => __x(
            'Cannot find change {id} ({change}) in {file}',
            id     => $state->{change_id},
            change => join(' ', $state->{change}, @{ $state->{tags} || [] }),
            file   => $plan->file,
        );

        my $change = $plan->change_at($idx);
        if ($state->{change_id} eq $change->old_id) {
            # Old IDs need to be replaced.
            $idx    = $self->_update_ids;
            $change = $plan->change_at($idx);
        }

        # Upgrade the registry if there is no script_hash column.
        unless ( exists $state->{script_hash} ) {
            $self->upgrade_registry;
            $state->{script_hash} = $state->{change_id};
        }

        # Update the script hashes if they're the same as the change ID.
        $self->_update_script_hashes if $state->{script_hash}
            && $state->{script_hash} eq $state->{change_id};

        $plan->position($idx);
        if (my @tags = $change->tags) {
            $self->log_new_tags($change);
            $self->start_at( $change->format_name . $tags[-1]->format_name );
        } else {
            $self->start_at( $change->format_name );
        }

    } else {
        $plan->reset;
    }
    return $plan;
}

sub _update_ids {
    # We do nothing but inform, by default.
    my $self = shift;
    $self->sqitch->info(__x(
        'Updating legacy change and tag IDs in {destination}',
        destination => $self->destination,
    ));
    return $self;
}

sub is_deployed {
    my ($self, $thing) = @_;
    return $thing->isa('App::Sqitch::Plan::Tag')
        ? $self->is_deployed_tag($thing)
        : $self->is_deployed_change($thing);
}

sub deploy_change {
    my ( $self, $change ) = @_;
    my $sqitch = $self->sqitch;
    my $name = $change->format_name_with_tags;
    $sqitch->info_literal(
        "  + $name ..",
        '.' x ($self->max_name_length - length $name), ' '
    );
    $self->begin_work($change);

    return try {
        $self->run_deploy($change->deploy_file) unless $self->log_only;
        try {
            $self->verify_change( $change ) if $self->with_verify;
            $self->log_deploy_change($change);
            $sqitch->info(__ 'ok');
        } catch {
            # Oy, logging or verify failed. Rollback.
            $sqitch->vent(eval { $_->message } // $_);
            $self->rollback_work($change);

            # Begin work and run the revert.
            try {
                # Don't bother displaying the reverting change name.
                # $self->sqitch->info('  - ', $change->format_name_with_tags);
                $self->begin_work($change);
                $self->run_revert($change->revert_file) unless $self->log_only;
            } catch {
                # Oy, the revert failed. Just emit the error.
                $sqitch->vent(eval { $_->message } // $_);
            };
            hurl private => __ 'Deploy failed';
        };
    } finally {
        $self->finish_work($change);
    } catch {
        $self->log_fail_change($change);
        $sqitch->info(__ 'not ok');
        die $_;
    };
}

sub revert_change {
    my ( $self, $change ) = @_;
    my $sqitch = $self->sqitch;
    my $name   = $change->format_name_with_tags;
    $sqitch->info_literal(
        "  - $name ..",
        '.' x ($self->max_name_length - length $name), ' '
    );

    $self->begin_work($change);

    try {
        $self->run_revert($change->revert_file) unless $self->log_only;
        try {
            $self->log_revert_change($change);
            $sqitch->info(__ 'ok');
        } catch {
            # Oy, our logging died. Rollback and revert this change.
            $self->sqitch->vent(eval { $_->message } // $_);
            $self->rollback_work($change);
            hurl revert => 'Revert failed';
        };
    } finally {
        $self->finish_work($change);
    } catch {
        $sqitch->info(__ 'not ok');
        die $_;
    };
}

sub begin_work  { shift }
sub finish_work { shift }
sub rollback_work { shift }

sub earliest_change {
    my $self = shift;
    my $change_id = $self->earliest_change_id(@_) // return undef;
    return $self->plan->get( $change_id );
}

sub latest_change {
    my $self = shift;
    my $change_id = $self->latest_change_id(@_) // return undef;
    return $self->plan->get( $change_id );
}

sub needs_upgrade {
    my $self = shift;
    $self->registry_version != $self->registry_release;
}

sub _check_registry {
    my $self   = shift;
    my $newver = $self->registry_release;
    my $oldver = $self->registry_version;
    return $self if $newver == $oldver;

    hurl engine => __x(
        'No registry found in {destination}. Have you ever deployed?',
        destination => $self->registry_destination,
    ) if $oldver == 0 && !$self->initialized;

    hurl engine => __x(
        'Registry version is {old} but {new} is the latest known. Please upgrade Sqitch',
        old => $oldver,
        new => $newver,
    ) if $newver < $oldver;

    hurl engine => __x(
        'Registry is at version {old} but latest is {new}. Please run the "upgrade" conmand',
        old => $oldver,
        new => $newver,
    ) if $newver > $oldver;
}

sub upgrade_registry {
    my $self    = shift;
    return $self unless $self->needs_upgrade;

    my $sqitch = $self->sqitch;
    my $newver = $self->registry_release;
    my $oldver = $self->registry_version;

    hurl __x(
        'Registry version is {old} but {new} is the latest known. Please upgrade Sqitch.',
        old => $oldver,
        new => $newver,
    ) if $newver < $oldver;

    my $key    = $self->key;
    my $dir    = file(__FILE__)->dir->subdir(qw(Engine Upgrade));

    my @scripts = sort { $a->[0] <=> $b->[0] } grep { $_->[0] > $oldver } map {
       $_->basename =~ /\A\Q$key\E-(\d(?:[.]\d*)?)/;
       [ $1 || 0, $_ ];
    } $dir->children;

    # Make sure we're upgrading to where we want to be.
    hurl engine => __x(
        'Cannot upgrade to {version}: Cannot find upgrade script "{file}"',
        version => $newver,
        file    => $dir->file("$key-$newver.*"),
    ) unless @scripts && $scripts[-1]->[0] == $newver;

    # Run the upgrades.
    for my $script (@scripts) {
        my ($version, $file) = @{ $script };
        $sqitch->info('  * ' . __x(
            'From {old} to {new}',
            old => $oldver,
            new => $version,
        ));
        $self->run_upgrade($file);
        $self->_register_release($version);
        $oldver = $version;
    }

    return $self;
}

sub initialized {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented initialized()";
}

sub initialize {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented initialize()";
}

sub register_project {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented register_project()";
}

sub run_file {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented run_file()";
}

sub run_handle {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented run_handle()";
}

sub log_deploy_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_deploy_change()";
}

sub log_fail_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_fail_change()";
}

sub log_revert_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_revert_change()";
}

sub log_new_tags {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented log_new_tags()";
}

sub is_deployed_tag {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented is_deployed_tag()";
}

sub is_deployed_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented is_deployed_change()";
}

sub are_deployed_changes {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented are_deployed_changes()";
}

sub change_id_for {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented change_id_for()";
}

sub earliest_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented earliest_change_id()";
}

sub latest_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented latest_change_id()";
}

sub deployed_changes {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented deployed_changes()";
}

sub deployed_changes_since {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented deployed_changes_since()";
}

sub load_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented load_change()";
}

sub changes_requiring_change {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented changes_requiring_change()";
}

sub name_for_change_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented name_for_change_id()";
}

sub change_offset_from_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented change_offset_from_id()";
}

sub change_id_offset_from_id {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented change_id_offset_from_id()";
}

sub registered_projects {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented registered_projects()";
}

sub current_state {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_state()";
}

sub current_changes {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_changes()";
}

sub current_tags {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented current_tags()";
}

sub search_events {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented search_events()";
}

sub registry_version {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented registry_version()";
}

sub _update_script_hashes {
    my $class = ref $_[0] || $_[0];
    hurl "$class has not implemented _update_script_hashes()";
}

1;

__END__

=head1 Name

App::Sqitch::Engine - Sqitch Deployment Engine

=head1 Synopsis

  my $engine = App::Sqitch::Engine->new( sqitch => $sqitch );

=head1 Description

App::Sqitch::Engine provides the base class for all Sqitch storage engines.
Most likely this will not be of much interest to you unless you are hacking on
the engine code.

=head1 Interface

=head2 Class Methods

=head3 C<key>

  my $name = App::Sqitch::Engine->key;

The key name of the engine. Should be the last part of the package name.

=head3 C<name>

  my $name = App::Sqitch::Engine->name;

The name of the engine. Returns the same value as C<key> by default, but
should probably be overridden to return a display name for the engine.

=head3 C<default_registry>

  my $reg = App::Sqitch::Engine->default_registry;

Returns the name of the default registry for the engine. Most engines just
inherit the default value, C<sqitch>, but some must do more munging, such as
specifying a file name, to determine the default registry name.

=head3 C<default_client>

  my $cli = App::Sqitch::Engine->default_client;

Returns the name of the default client for the engine. Must be implemented by
each engine.

=head3 C<driver>

  my $driver = App::Sqitch::Engine->driver;

The name and version of the database driver to use with the engine, returned
as a string suitable for passing to C<use>. Used internally by C<use_driver()>
to C<use> the driver and, if it dies, to display an appropriate error message.
Must be overridden by subclasses.

=head3 C<use_driver>

  App::Sqitch::Engine->use_driver;

Uses the driver and version returned by C<driver>. Returns an error on failure
and returns true on success.

=head3 C<config_vars>

  my %vars = App::Sqitch::Engine->config_vars;

Returns a hash of names and types to use for configuration variables for the
engine. These can be set under the C<engine.$engine_name> section in any
configuration file.

The keys in the returned hash are the names of the variables. The values are
the data types. Valid data types include:

=over

=item C<any>

=item C<int>

=item C<num>

=item C<bool>

=item C<bool-or-int>

=back

Values ending in C<+> (a plus sign) may be specified multiple times. Example:

  (
      client => 'any',
      host   => 'any',
      port   => 'int',
      set    => 'any+',
  )

In this example, the C<port> variable will be stored and retrieved as an
integer. The C<set> variable may be of any type and may be included multiple
times. All the other variables may be of any type.

By default, App::Sqitch::Engine returns:

  (
      target   => 'any',
      registry => 'any',
      client   => 'any',
  )

Subclasses for supported engines will return more.

=head3 C<registry_release>

Returns the version of the registry understood by this release of Sqitch. The
C<needs_upgrade()> method compares this value to that returned by
C<registry_version()> to determine whether the target's registry needs
upgrading.

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

=head2 Instance Accessors

=head3 C<sqitch>

The current Sqitch object.

=head3 C<target>

An L<App::Sqitch::Target> object identifying the database target, usually
derived from the name of target specified on the command-line, or the default.

=head3 C<uri>

A L<URI::db> object representing the target database. Defaults to a URI
constructed from the L<App::Sqitch> C<db_*> attributes.

=head3 C<destination>

A string identifying the target database. Usually the same as the C<target>,
unless it's a URI with the password included, in which case it returns the
value of C<uri> with the password removed.

=head3 C<registry>

The name of the registry schema or database.

=head3 C<start_at>

The point in the plan from which to start deploying changes.

=head3 C<no_prompt>

Boolean indicating whether or not to prompt for reverts. False by default.

=head3 C<log_only>

Boolean indicating whether or not to log changes I<without running deploy or
revert scripts>. This is useful for an existing database schema that needs to
be converted to Sqitch. False by default.

=head3 C<with_verify>

Boolean indicating whether or not to run the verification script after each
deploy script. False by default.

=head3 C<variables>

A hash of engine client variables to be set. May be set and retrieved as a
list.

=head2 Instance Methods

=head3 C<username>

  my $username = $engine->username;

The username to use to connect to the database, for engines that require
authentication. The username is looked up in the following places, returning
the first to have a value:

=over

=item 1.

The C<$SQITCH_USERNAME> environment variable.

=item 2.

The username from the target URI.

=item 3.

An engine-specific default password, which may be derived from an environment
variable, engine configuration file, the system user, or none at all.

=back

See L<sqitch-passwords> for details and best practices for Sqitch engine
authentication.

=head3 C<password>

  my $password = $engine->password;

The password to use to connect to the database, for engines that require
authentication. The password is looked up in the following places, returning
the first to have a value:

=over

=item 1.

The C<$SQITCH_PASSWORD> environment variable.

=item 2.

The password from the target URI.

=item 3.

An engine-specific default password, which may be derived from an environment
variable, engine configuration file, or none at all.

=back

See L<sqitch-passwords> for details and best practices for Sqitch engine
authentication.

=head3 C<registry_destination>

  my $registry_destination = $engine->registry_destination;

Returns the name of the registry database. In other words, the database in
which Sqitch's own data is stored. It will usually be the same as C<target()>,
but some engines, such as L<SQLite|App::Sqitch::Engine::sqlite>, may use a
separate database. Used internally to name the target when the registration
tables are created.

=head3 C<variables>

=head3 C<set_variables>

=head3 C<clear_variables>

  my %vars = $engine->variables;
  $engine->set_variables(foo => 'bar', baz => 'hi there');
  $engine->clear_variables;

Get, set, and clear engine variables. Variables are defined as key/value pairs
to be passed to the engine client in calls to C<deploy> and C<revert>, if the
client supports variables. For example, the
L<PostgreSQL|App::Sqitch::Engine::pg> and
L<Vertica|App::Sqitch::Engine::vertica> engines pass all the variables to
their C<psql> and C<vsql> clients via the C<--set> option, while the
L<MySQL engine|App::Sqitch::Engine::mysql> engine sets them via the C<SET>
command and the L<Oracle engine|App::Sqitch::Engine::oracle> engine sets them
via the SQL*Plus C<DEFINE> command.


=head3 C<deploy>

  $engine->deploy($to_change);
  $engine->deploy($to_change, $mode);
  $engine->deploy($to_change, $mode);

Deploys changes to the target database, starting with the current deployment
state, and continuing to C<$to_change>. C<$to_change> must be a valid change
specification as passable to the C<index_of()> method of L<App::Sqitch::Plan>.
If C<$to_change> is not specified, all changes will be applied.

The second argument specifies the reversion mode in the case of deployment
failure. The allowed values are:

=over

=item C<all>

In the event of failure, revert all deployed changes, back to the point at
which deployment started. This is the default.

=item C<tag>

In the event of failure, revert all deployed changes to the last
successfully-applied tag. If no tags were applied during this deployment, all
changes will be reverted to the pint at which deployment began.

=item C<change>

In the event of failure, no changes will be reverted. This is on the
assumption that a change failure is total, and the change may be applied again.

=back

Note that, in the event of failure, if a reversion fails, the target database
B<may be left in a corrupted state>. Write your revert scripts carefully!

=head3 C<revert>

  $engine->revert;
  $engine->revert($tag);
  $engine->revert($tag);

Reverts the L<App::Sqitch::Plan::Tag> from the database, including all of its
associated changes.

=head3 C<verify>

  $engine->verify;
  $engine->verify( $from );
  $engine->verify( $from, $to );
  $engine->verify( undef, $to );

Verifies the database against the plan. Pass in change identifiers, as
described in L<sqitchchanges>, to limit the changes to verify. For each
change, information will be emitted if:

=over

=item *

It does not appear in the plan.

=item *

It has not been deployed to the database.

=item *

It has been deployed out-of-order relative to the plan.

=item *

Its verify script fails.

=back

Changes without verify scripts will emit a warning, but not constitute a
failure. If there are any failures, an exception will be thrown once all
verifications have completed.

=head3 C<check_deploy_dependencies>

  $engine->check_deploy_dependencies;
  $engine->check_deploy_dependencies($to_index);

Validates that all dependencies will be met for all changes to be deployed,
starting with the currently-deployed change up to the specified index, or to
the last change in the plan if no index is passed. If any of the changes to be
deployed would conflict with previously-deployed changes or are missing any
required changes, an exception will be thrown. Used internally by C<deploy()>
to ensure that dependencies will be satisfied before deploying any changes.

=head3 C<check_revert_dependencies>

  $engine->check_revert_dependencies(@changes);

Validates that the list of changes to be reverted, which should be passed in
the order in which they will be reverted, are not depended upon by other
changes. If any are depended upon by other changes, an exception will be
thrown listing the changes that cannot be reverted and what changes depend on
them. Used internally by C<revert()> to ensure no dependencies will be
violated before revering any changes.

=head3 C<deploy_change>

  $engine->deploy_change($change);
  $engine->deploy_change($change);

Used internally by C<deploy()> to deploy an individual change.

=head3 C<revert_change>

  $engine->revert_change($change);
  $engine->revert_change($change);

Used internally by C<revert()> (and, by C<deploy()> when a deploy fails) to
revert an individual change.

=head3 C<verify_change>

  $engine->verify_change($change);

Used internally by C<deploy_change()> to verify a just-deployed change if
C<with_verify> is true.

=head3 C<is_deployed>

  say "Tag deployed"  if $engine->is_deployed($tag);
  say "Change deployed" if $engine->is_deployed($change);

Convenience method that dispatches to C<is_deployed_tag()> or
C<is_deployed_change()> as appropriate to its argument.

=head3 C<earliest_change>

  my $change = $engine->earliest_change;
  my $change = $engine->earliest_change($offset);

Returns the L<App::Sqitch::Plan::Change> object representing the earliest
applied change. With the optional C<$offset> argument, the returned change
will be the offset number of changes following the earliest change.


=head3 C<latest_change>

  my $change = $engine->latest_change;
  my $change = $engine->latest_change($offset);

Returns the L<App::Sqitch::Plan::Change> object representing the latest
applied change. With the optional C<$offset> argument, the returned change
will be the offset number of changes before the latest change.

=head3 C<change_for_key>

  my $change = if $engine->change_for_key($key);

Searches the deployed changes for a change corresponding to the specified key,
which should be in a format as described in L<sqitchchanges>. Throws an
exception if the key matches more than one changes. Returns C<undef> if it
matches no changes.

=head3 C<change_id_for_key>

  my $change_id = if $engine->change_id_for_key($key);

Searches the deployed changes for a change corresponding to the specified key,
which should be in a format as described in L<sqitchchanges>, and returns the
change's ID. Throws an exception if the key matches more than one change.
Returns C<undef> if it matches no changes.

=head3 C<change_for_key>

  my $change = if $engine->change_for_key($key);

Searches the list of deployed changes for a change corresponding to the
specified key, which should be in a format as described in L<sqitchchanges>.
Throws an exception if the key matches multiple changes.

=head3 C<change_id_for_depend>

  say 'Dependency satisfied' if $engine->change_id_for_depend($depend);

Returns the change ID for a L<dependency|App::Sqitch::Plan::Depend>, if the
dependency resolves to a change currently deployed to the database. Returns
C<undef> if the dependency resolves to no currently-deployed change.

=head3 C<find_change>

  my $change = $engine->find_change(%params);

Finds and returns a deployed change, or C<undef> if the change has not been
deployed. The supported parameters are:

=over

=item C<change_id>

The change ID.

=item C<change>

A change name.

=item C<tag>

A tag name.

=item C<project>

A project name. Defaults to the current project.

=item C<offset>

The number of changes offset from the change found by the other parameters
should actually be returned. May be positive or negative.

=back

The order of precedence for the search is:

=over

=item 1.

Search by change ID, if passed.

=item 2.

Search by change name as of tag, if both are passed.

=item 3.

Search by change name or tag.

=back

The offset, if passed, will be applied relative to whatever change is found by
the above algorithm.

=head3 C<find_change_id>

  my $change_id = $engine->find_change_id(%params);

Like C<find_change()>, taking the same parameters, but returning an ID instead
of a change.

=head3 C<run_deploy>

  $engine->run_deploy($deploy_file);

Runs a deploy script. The implementation is just an alias for C<run_file()>;
subclasses may override as appropriate.

=head3 C<run_revert>

  $engine->run_revert($revert_file);

Runs a revert script. The implementation is just an alias for C<run_file()>;
subclasses may override as appropriate.

=head3 C<run_verify>

  $engine->run_verify($verify_file);

Runs a verify script. The implementation is just an alias for C<run_file()>;
subclasses may override as appropriate.

=head3 C<run_upgrade>

  $engine->run_upgrade($upgrade_file);

Runs an upgrade script. The implementation is just an alias for C<run_file()>;
subclasses may override as appropriate.

=head3 C<needs_upgrade>

  if ($engine->needs_upgrade) {
      $engine->upgrade_registry;
  }

Determines if the target's registry needs upgrading and returns true if it
does.

=head3 C<upgrade_registry>

  $engine->upgrade_registry;

Upgrades the target's registry, if it needs upgrading. Used by the
L<C<upgrade>|App::Sqitch::Command::upgrade> command.

=head2 Abstract Instance Methods

These methods must be overridden in subclasses.

=head3 C<begin_work>

  $engine->begin_work($change);

This method is called just before a change is deployed or reverted. It should
create a lock to prevent any other processes from making changes to the
database, to be freed in C<finish_work> or C<rollback_work>.

=head3 C<finish_work>

  $engine->finish_work($change);

This method is called after a change has been deployed or reverted. It should
unlock the lock created by C<begin_work>.

=head3 C<rollback_work>

  $engine->rollback_work($change);

This method is called after a change has been deployed or reverted and the
logging of that change has failed. It should rollback changes started by
C<begin_work>.

=head3 C<initialized>

  $engine->initialize unless $engine->initialized;

Returns true if the database has been initialized for Sqitch, and false if it
has not.

=head3 C<initialize>

  $engine->initialize;

Initializes the target database for Sqitch by installing the Sqitch registry
schema and/or tables. Should be overridden by subclasses. This implementation
throws an exception

=head3 C<register_project>

  $engine->register_project;

Registers the current project plan in the registry database. The
implementation should insert the project name and URI if they have not already
been inserted. If a project with the same name but different URI already
exists, an exception should be thrown.

=head3 C<is_deployed_tag>

  say 'Tag deployed' if $engine->is_deployed_tag($tag);

Should return true if the L<tag|App::Sqitch::Plan::Tag> has been applied to
the database, and false if it has not.

=head3 C<is_deployed_change>

  say 'Change deployed' if $engine->is_deployed_change($change);

Should return true if the L<change|App::Sqitch::Plan::Change> has been
deployed to the database, and false if it has not.

=head3 C<are_deployed_changes>

  say "Change $_ is deployed" for $engine->are_deployed_change(@changes);

Should return the IDs of any of the changes passed in that are currently
deployed. Used by C<deploy> to ensure that no changes already deployed are
re-deployed.

=head3 C<change_id_for>

  say $engine->change_id_for(
      change  => $change_name,
      tag     => $tag_name,
      offset  => $offset,
      project => $project,
);

Searches the database for the change with the specified name, tag, and offset.
Throws an exception if the key matches more than one changes. Returns C<undef>
if it matches no changes. The parameters are as follows:

=over

=item C<change>

The name of a change. Required unless C<tag> is passed.

=item C<tag>

The name of a tag. Required unless C<change> is passed.

=item C<offset>

The number of changes offset from the change found by the tag and/or change
name. May be positive or negative to mean later or earlier changes,
respectively. Defaults to 0.

=item C<project>

The name of the project to search. Defaults to the current project.

=back

If both C<change> and C<tag> are passed, C<find_change_id> will search for the
last instance of the named change deployed I<before> the tag.

=head3 C<changes_requiring_change>

  my @requiring = $engine->changes_requiring_change($change);

Returns a list of hash references representing currently deployed changes that
require the passed change. When this method returns one or more hash
references, the change should not be reverted. Each hash reference should
contain the following keys:

=over

=item C<change_id>

The requiring change ID.

=item C<change>

The requiring change name.

=item C<project>

The project the requiring change is from.

=item C<asof_tag>

Name of the first tag to be applied after the requiring change was deployed,
if any.

=back

=head3 C<log_deploy_change>

  $engine->log_deploy_change($change);

Should write the records to the registry necessary to indicate that the change
has been deployed.

=head3 C<log_fail_change>

  $engine->log_fail_change($change);

Should write to the database event history a record reflecting that deployment
of the change failed.

=head3 C<log_revert_change>

  $engine->log_revert_change($change);

Should write to and/or remove from the registry the records necessary to
indicate that the change has been reverted.

=head3 C<log_new_tags>

  $engine->log_new_tags($change);

Given a change, if it has any tags that are not currently logged in the
database, they should be logged. This is assuming, of course, that the change
itself has previously been logged.

=head3 C<earliest_change_id>

  my $change_id = $engine->earliest_change_id($offset);

Returns the ID of the earliest applied change from the current project. With
the optional C<$offset> argument, the ID of the change the offset number of
changes following the earliest change will be returned.

=head3 C<latest_change_id>

  my $change_id = $engine->latest_change_id;
  my $change_id = $engine->latest_change_id($offset);

Returns the ID of the latest applied change from the current project.
With the optional C<$offset> argument, the ID of the change the offset
number of changes before the latest change will be returned.

=head3 C<deployed_changes>

  my @change_hashes = $engine->deployed_changes;

Returns a list of hash references, each representing a change from the current
project in the order in which they were deployed. The keys in each hash
reference must be:

=over

=item C<id>

The change ID.

=item C<name>

The change name.

=item C<project>

The name of the project with which the change is associated.

=item C<note>

The note attached to the change.

=item C<planner_name>

The name of the user who planned the change.

=item C<planner_email>

The email address of the user who planned the change.

=item C<timestamp>

An L<App::Sqitch::DateTime> object representing the time the change was planned.

=item C<tags>

An array reference of the tag names associated with the change.

=back

=head3 C<deployed_changes_since>

  my @change_hashes = $engine->deployed_changes_since($change);

Returns a list of hash references, each representing a change from the current
project deployed after the specified change. The keys in the hash references
should be the same as for those returned by C<deployed_changes()>.

=head3 C<name_for_change_id>

  my $change_name = $engine->name_for_change_id($change_id);

Returns the tag-qualified name of the change identified by the ID. If a tag
was applied to a change after that change, the name will be returned with the
tag qualification, e.g., C<app_user@beta>. Otherwise, it will include the
symbolic tag C<@HEAD>. e.g., C<widgets@HEAD>. This value should be suitable
for uniquely identifying the change, and passing to the C<get> or C<index_of>
methods of L<App::Sqitch::Plan>.

=head3 C<registered_projects>

  my @projects = $engine->registered_projects;

Returns a list of the names of Sqitch projects registered in the database.

=head3 C<current_state>

  my $state = $engine->current_state;
  my $state = $engine->current_state($project);

Returns a hash reference representing the current project deployment state of
the database, or C<undef> if the database has no changes deployed. If a
project name is passed, the state will be returned for that project. Otherwise,
the state will be returned for the local project.

The hash contains information about the last successfully deployed change, as
well as any associated tags. The keys to the hash should include:

=over

=item C<project>

The name of the project for which the state is reported.

=item C<change_id>

The current change ID.

=item C<script_hash>

The deploy script SHA-1 hash.

=item C<change>

The current change name.

=item C<note>

A brief description of the change.

=item C<tags>

An array reference of the names of associated tags.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was deployed.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head3 C<current_changes>

  my $iter = $engine->current_changes;
  my $iter = $engine->current_changes($project);
  while (my $change = $iter->()) {
      say '* ', $change->{change};
  }

Returns a code reference that iterates over a list of the currently deployed
changes in reverse chronological order. If a project name is not passed, the
current project will be assumed. Each change is represented by a hash
reference containing the following keys:

=over

=item C<change_id>

The current change ID.

=item C<script_hash>

The deploy script SHA-1 hash.

=item C<change>

The current change name.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was deployed.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head3 C<current_tags>

  my $iter = $engine->current_tags;
  my $iter = $engine->current_tags($project);
  while (my $tag = $iter->()) {
      say '* ', $tag->{tag};
  }

Returns a code reference that iterates over a list of the currently deployed
tags in reverse chronological order. If a project name is not passed, the
current project will be assumed. Each tag is represented by a hash reference
containing the following keys:

=over

=item C<tag_id>

The tag ID.

=item C<tag>

The name of the tag.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
tag was applied.

=item C<committer_name>

Name of the user who applied the tag.

=item C<committer_email>

Email address of the user who applied the tag.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
tag was added to the plan.

=item C<planner_name>

Name of the user who added the tag to the plan.

=item C<planner_email>

Email address of the user who added the tag to the plan.

=back

=head3 C<search_events>

  my $iter = $engine->search_events( %params );
  while (my $change = $iter->()) {
      say '* $change->{event}ed $change->{change}";
  }

Searches the deployment event log and returns an iterator code reference with
the results. If no parameters are provided, a list of all events will be
returned from the iterator reverse chronological order. The supported parameters
are:

=over

=item C<event>

An array of the type of event to search for. Allowed values are "deploy",
"revert", and "fail".

=item C<project>

Limit the events to those with project names matching the specified regular
expression.

=item C<change>

Limit the events to those with changes matching the specified regular
expression.

=item C<committer>

Limit the events to those logged for the actions of the committers with names
matching the specified regular expression.

=item C<planner>

Limit the events to those with changes who's planner's name matches the
specified regular expression.

=item C<limit>

Limit the number of events to the specified number.

=item C<offset>

Skip the specified number of events.

=item C<direction>

Return the results in the specified order, which must be a value matching
C</^(:?a|de)sc/i> for "ascending" or "descending".

=back

Each event is represented by a hash reference containing the following keys:

=over

=item C<event>

The type of event, which is one of:

=over

=item C<deploy>

=item C<revert>

=item C<fail>

=back

=item C<project>

The name of the project with which the change is associated.

=item C<change_id>

The change ID.

=item C<change>

The name of the change.

=item C<note>

A brief description of the change.

=item C<tags>

An array reference of the names of associated tags.

=item C<requires>

An array reference of the names of any changes required by the change.

=item C<conflicts>

An array reference of the names of any changes that conflict with the change.

=item C<committed_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
event was logged.

=item C<committer_name>

Name of the user who deployed the change.

=item C<committer_email>

Email address of the user who deployed the change.

=item C<planned_at>

An L<App::Sqitch::DateTime> object representing the date and time at which the
change was added to the plan.

=item C<planner_name>

Name of the user who added the change to the plan.

=item C<planner_email>

Email address of the user who added the change to the plan.

=back

=head3 C<run_file>

  $engine->run_file($file);

Should execute the commands in the specified file. This will generally be an
SQL file to run through the engine's native client.

=head3 C<run_handle>

  $engine->run_handle($file_handle);

Should execute the commands in the specified file handle. The file handle's
contents should be piped to the engine's native client.

=head3 C<load_change>

  my $change = $engine->load_change($change_id);

Given a deployed change ID, loads an returns a hash reference representing the
change in the database. The keys should be the same as those in the hash
references returned by C<deployed_changes()>. Returns C<undef> if the change
has not been deployed.

=head3 C<change_offset_from_id>

  my $change = $engine->change_offset_from_id( $change_id, $offset );

Given a change ID and an offset, returns a hash reference of the data for a
deployed change (with the same keys as defined for C<deployed_changes()>) in
the current project that was deployed C<$offset> steps before the change
identified by C<$change_id>. If C<$offset> is C<0> or C<undef>, the change
represented by C<$change_id> should be returned (just like C<load_change()>).
Otherwise, the change returned should be C<$offset> steps from that change ID,
where C<$offset> may be positive (later step) or negative (earlier step).
Returns C<undef> if the change was not found or if the offset is more than the
number of changes before or after the change, as appropriate.

=head3 C<change_id_offset_from_id>

  my $id = $engine->change_id_offset_from_id( $change_id, $offset );

Like C<change_offset_from_id()> but returns the change ID rather than the
change object.

=head3 C<registry_version>

Should return the current version of the target's registry.

=head1 See Also

=over

=item L<sqitch>

The Sqitch command-line client.

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
