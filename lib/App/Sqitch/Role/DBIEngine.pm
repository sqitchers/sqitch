package App::Sqitch::Role::DBIEngine;

use 5.010;
use strict;
use warnings;
use utf8;
use Mouse::Role;
use namespace::autoclean;
use Try::Tiny;
use App::Sqitch::X qw(hurl);

our $VERSION = '0.954';

requires '_dbh';
requires 'plan';
requires '_regex_op';
requires '_ts2char_format';

sub _ts2char {
    my $format = $_[0]->_ts2char_format;
    sprintf $format => $_[1];
}

sub _dt($) {
    require App::Sqitch::DateTime;
    return App::Sqitch::DateTime->new(split /:/ => shift);
}

sub _cid {
    my ( $self, $ord, $offset, $project ) = @_;
    return try {
        $self->_dbh->selectcol_arrayref(qq{
            SELECT change_id
              FROM changes
             WHERE project = ?
             ORDER BY committed_at $ord
             LIMIT 1
            OFFSET COALESCE(?, 0)
        }, undef, $project || $self->plan->project, $offset)->[0];
    } catch {
        # Too bad $DBI::state isn't set to an SQL error coee. :-(
        return if $DBI::errstr eq 'no such table: changes';
        die $_;
    };
}

sub earliest_change_id {
    shift->_cid('ASC', @_);
}

sub latest_change_id {
    shift->_cid('DESC', @_);
}

sub current_state {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $dbh    = $self->_dbh;
    my $state  = $dbh->selectrow_hashref(qq{
        SELECT change_id
             , change
             , project
             , note
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         WHERE project = ?
         ORDER BY changes.committed_at DESC
         LIMIT 1
    }, undef, $project // $self->plan->project ) or return undef;
    $state->{committed_at} = _dt $state->{committed_at};
    $state->{planned_at}   = _dt $state->{planned_at};
    $state->{tags}         = $dbh->selectcol_arrayref(
        'SELECT tag FROM tags WHERE change_id = ? ORDER BY committed_at',
        undef, $state->{change_id}
    );
    return $state;
}

sub current_changes {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth    = $self->_dbh->prepare(qq{
        SELECT change_id
             , change
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM changes
         WHERE project = ?
         ORDER BY changes.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub current_tags {
    my ( $self, $project ) = @_;
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth    = $self->_dbh->prepare(qq{
        SELECT tag_id
             , tag
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM tags
         WHERE project = ?
         ORDER BY tags.committed_at DESC
    });
    $sth->execute($project // $self->plan->project);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

sub search_events {
    my ( $self, %p ) = @_;

    # Determine order direction.
    my $dir = 'DESC';
    if (my $d = delete $p{direction}) {
        $dir = $d =~ /^ASC/i  ? 'ASC'
             : $d =~ /^DESC/i ? 'DESC'
             : hurl 'Search direction must be either "ASC" or "DESC"';
    }

    # Limit with regular expressions?
    my (@wheres, @params);
    my $op = $self->_regex_op;
    for my $spec (
        [ committer => 'committer_name' ],
        [ planner   => 'planner_name'   ],
        [ change    => 'change'         ],
        [ project   => 'project'        ],
    ) {
        my $regex = delete $p{ $spec->[0] } // next;
        push @wheres => "$spec->[1] $op ?";
        push @params => $regex;
    }

    # Match events?
    if (my $e = delete $p{event} ) {
        my $qs = ('?') x @{ $e };
        push @wheres => "event IN ($qs)";
        push @params => $ { $e };
    }

    # Assemble the where clause.
    my $where = @wheres
        ? "\n         WHERE " . join( "\n               ", @wheres )
        : '';

    # Handle remaining parameters.
    my $limits = join '  ' => map {
        push @params => $p{$_};
        uc "\n         $_ ?"
    } grep { $p{$_} } qw(limit offset);

    hurl 'Invalid parameters passed to search_events(): '
        . join ', ', sort keys %p if %p;

    # Prepare, execute, and return.
    my $cdtcol = $self->_ts2char('committed_at');
    my $pdtcol = $self->_ts2char('planned_at');
    my $sth = $self->_dbh->prepare(qq{
        SELECT event
             , project
             , change_id
             , change
             , note
             , requires
             , conflicts
             , tags
             , committer_name
             , committer_email
             , $cdtcol AS committed_at
             , planner_name
             , planner_email
             , $pdtcol AS planned_at
          FROM events$where
         ORDER BY events.committed_at $dir$limits
    });
    $sth->execute(@params);
    return sub {
        my $row = $sth->fetchrow_hashref or return;
        $row->{committed_at} = _dt $row->{committed_at};
        $row->{planned_at}   = _dt $row->{planned_at};
        return $row;
    };
}

1;

__END__

=head1 Name

App::Sqitch::Command::checkout - An engine based on the DBI

=head1 Synopsis

  package App::Sqitch::Engine::sqlite;
  extends 'App::Sqitch::Engine';
  with 'App::Sqitch::Role::DBIEngine';

=head1 Description

This role encapsulates the common attributes and methods required by
DBI-powered engines.

=head1 Interface

=head2 Instance Methods

=head3 C<earliest_change_id>

=head3 C<latest_change_id>

=head3 C<current_state>

=head3 C<current_changes>

=head3 C<current_tags>

=head3 C<search_events>

=head1 See Also

=over

=item L<App::Sqitch::Engine::sqlite>

The SQLite engine.

=item L<App::Sqitch::Engine::pg>

The PostgreSQL engine.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2013 iovation Inc.

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
