package App::Sqitch::Engine::redshift;

use 5.010;
use Moo;
use utf8;
use Path::Class;
use Try::Tiny;
use namespace::autoclean;

extends 'App::Sqitch::Engine::pg';

sub key    { 'redshift' }
sub name   { 'Redshift' }
sub driver { 'DBD::Pg 2.0' }
sub default_client { 'psql' }

sub _registry_file{ file(__FILE__)->dir->file('redshift.sql') }

sub _ts_default { 'GETDATE()' }

sub _ts2char_format {
    q{'year:' || to_char(%1$s, 'YYYY') || ':month:' || to_char(%1$s, 'MM') || ':day:' || to_char(%1$s, 'DD') || ':hour:' || to_char(%1$s, 'HH24') || ':minute:' || to_char(%1$s, 'MI') || ':second:' || to_char(%1$s, 'SS') || ':time_zone:UTC'};
}

sub _dbh_callback_connected {
    my ($self, $dbh) = @_;
    try {
        $dbh->do(
            'SET search_path = ?',
            undef, $self->registry
        );
        # http://www.nntp.perl.org/group/perl.dbi.dev/2013/11/msg7622.html
        $dbh->set_err(undef, undef) if $dbh->err;
    };
    return;
}

sub _tag_column {
    my ($self, $prefix) = @_;
    $prefix ||= '';
    $prefix &&= "${prefix}.";
    return qq|${prefix}"tag"|;
}

sub _listagg_format {
    q{listagg(%s, ' ')}
}

sub changes_requiring_change {
    my ( $self, $change ) = @_;
    my $tagcol = $self->_tag_column;
    return @{ $self->dbh->selectall_arrayref(qq{
        with asof_tag as (
            SELECT tags.$tagcol
            FROM dependencies d
            JOIN changes c1 ON c1.change_id = d.change_id
            JOIN changes c2 ON
              c2.project = c1.project
              AND c2.committed_at >= c1.committed_at
            JOIN tags ON c2.change_id = tags.change_id
            WHERE d.dependency_id = ?
            ORDER BY c2.committed_at
            LIMIT 1
        )
        SELECT c.change_id, c.project, c.change, asof_tag.$tagcol
        FROM dependencies d
        JOIN changes c ON c.change_id = d.change_id
          LEFT JOIN asof_tag ON 1=1
        WHERE d.dependency_id = ?
    }, { Slice => {} }, $change->id, $change->id) };
}

sub log_revert_change {
    my ($self, $change) = @_;
    return App::Sqitch::Role::DBIEngine::log_revert_change($self, $change);
}

1;

__END__

=head1 Name

App::Sqitch::Engine::redshift - Sqitch Redshift Engine

=head1 Synopsis

  my $redshift = App::Sqitch::Engine->load( engine => 'redshift' );

=head1 Description

App::Sqitch::Engine::redshift provides the AWS Redshift storage engine for
Sqitch. It mostly uses the PostgreSQL engine underneath.

=cut
