package App::Sqitch;

use v5.10;
use warnings;
use Getopt::Long;

our $VERSION = '0.10';

sub _getopt {
    my %opts;
    Getopt::Long::Configure (qw(bundling pass_through));
    Getopt::Long::GetOptions(
        'plan-file|p=s'          => \$opts{plan_file},
        'connect-to|connect|c=s' => \$opts{sql_dir},
        'sql-dir=s'              => \$opts{sql_dir},
        'deploy-dir=s'           => \$opts{deploy_dir},
        'revert-dir=s'           => \$opts{revert_dir},
        'test-dir=s'             => \$opts{test_dir},
        'extension=s'            => \$opts{extension},
        'dry-run'                => \$opts{dry_run},
        'verbose|v+'             => \$opts{verbose},
        'help|H'                 => \$opts{help},
        'man|M'                  => \$opts{man},
        'version|V'              => \$opts{version},
    ) or $self->_pod2usage;

    # Handle documentation requests.
    $self->_pod2usage(
        ( $opts{man} ? ( '-sections' => '.+' ) : ()),
        '-exitval' => 0,
    ) if $opts{help} or $opts{man};

    # Handle version request.
    if ($opts{version}) {
        print $fn, ' (', __PACKAGE__, ') ', __PACKAGE__->VERSION, $/;
        exit;
    }

}

sub _pod2usage {
    shift;
    require Pod::Usage;
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Options))',
        '-exitval'  => 1,
        '-input'    => __FILE__,
        @_
    );
}

1;

__END__

=head1 Name

sqitch - VCS-powered SQL Change Management

=head1 Synopsis

  sqitch [<options>] <command> [<command-options>] [<args>]

=head1 Description

Sqitch is a VCS-aware SQL change management application.

=head1 Options

  -p --plan-file  FILE  Path to a deployment plan file.
  -c --connect-to URI   URI to use to connect to the database.
     --sql-dir    DIR   Path to directory with deploy and revert scripts.
     --deploy-dir DIR   Path to directory with SQL deployment scripts.
     --revert-dir DIR   Path to directory with SQL reversion scripts.
     --test-dir   DIR   Path to directory with SQL test scripts.
     --extension  EXT   SQL script file name extension.
     --dry-run          Execute command without making any changes.
  -v --verbose          Increment verbosity.
  -V --version          Print the version number and exit.
  -H --help             Print a usage statement and exit.
  -M --man              Print the complete documentation and exit.

=head1 Options Details

=over

=item C<-c>

=item C<--connect>

=item C<--connect-to>

  sqitch --connect-to pg:postgres@localhost/mydb
  sqitch --connect sqlite:/tmp/widgets.db
  sqitch -c mysql:root@db.example.com:7777/bricolage

URI of the database to which to connect. For some RDBMSes, such as
L<PostgreSQL|http://postgresql.org/> and L<MySQL|http://mysql.org/>, the
database must already exist. For others, such as L<SQLite|http://sqlite.org/>,
the database will be automatically created on first connect.

The format of the URI as as follows:

  $rdbms:$user@$host:$port/$db

=over

=item C<$rdbms>

The RDBMS flavor. Required. Supported flavors include:

=over

=item * C<pg> - L<PostgreSQL|http://postgresql.org/>

=item * C<mysql> - L<MySQL|http://mysql.org/>

=item * C<sqlite> - L<SQLite|http://sqlite.org/>

=back

=item C<$user>

User name to use when connecting to the database. Optional.

=item C<$host>

RDBMS host name. Optional.

=item C<$port>

RDBMS port. Optional.

=item C<$db>

Name of the database. Required.

=back

=item C<-p>

=item C<--plan-file>

  sqitch --plan-file plan.conf
  sqitch -p sql/deploy.conf

Path to the deployment plan file. Defaults to F<./sqitch.plan>. If this file
is not present, Sqitch will attempt to read from VCS files. If no supported
VCS system is in place, an exception will be thrown. See L</Plan File> for a
description of its structure.

=item C<--sql-dir>

  sqitch --sql-dir migrations/

Path to directory containing deployment, reversion, and test SQL scripts. It
should contain subdirectories named C<deploy>, C<revert>, and (optionally)
C<test>. These may be overridden by C<--deploy-dir>, C<--revert-dir>, and
C<--test-dir>. Defaults to C<./sql>.

=item C<--deploy-dir>

  sqitch --deploy-dir db/up

Path to a directory containing SQL deployment scripts. Overrides the value
implied by C<--sql-dir>.

=item C<--revert-dir>

  sqitch --revert-dir db/up

Path to a directory containing SQL reversion scripts. Overrides the value
implied by C<--sql-dir>.

=item C<--test-dir>

  sqitch --test-dir db/t

Path to a directory containing SQL test scripts. Overrides the value implied
by C<--sql-dir>.

=item C<--extension>

  sqitch --extension ddl

The file name extension on deployment, reversion, and test SQL scripts.
Defaults to C<sql>.

=item C<--dry-run>

  sqitch --dry-run

Execute the Sqitch command without making any actual changes. This allows you
to see what Sqitch would actually do, without doing it. Implies a verbosity
level of 1; add extra C<--verbose>s for greater verbosity.

=item C<-v>

=item C<--verbose>

  sqitch --verbose -v

A value between 0 and 3 specifying how verbose Sqitch should be. The default
is 0, meaning that Sqitch will be silent. A value of 1 causes Sqitch to output
some information about what it's doing, while 2 and 3 each cause greater
verbosity.

=item C<-H>

=item C<--help>

  sqitch --help
  sqitch -H

Outputs a brief description of the options supported by C<sqitch> and exits.

=item C<-M>

=item C<--man>

  sqitch --man
  sqitch -M

Outputs this documentation and exits.

=item C<-V>

=item C<--version>

  sqitch --version
  sqitch -V

Outputs the program name and version and exits.

=back

=head1 Sqitch Commands

=over

=item C<init>

Initialize the database and create deployment script directories if the do
not already exist.

=item C<status>

Output information about the current status of the deployment, including a
list of tags, deployments, and dates in chronological order. If any deploy
scripts are not currently deployed, they will be listed separately.

=item C<check>

Sanity check the deployment scripts. Checks include:

=over

=item *

Make sure all deployment scripts have complementary reversion scripts.

=item *

Make sure no deployment script appears more than once in the plan file.

=back

=item C<deploy>

Deploy changes. Options:

=over

=item C<--to>

Tag to deploy up to. Defaults to the latest tag or to the VCS C<HEAD> commit.

=back

=item C<revert>

Revert changes. Options:

=over

=item C<--to>

Tag to revert to. Defaults to reverting all changes.

=back

=item C<test>

Test changes. All SQL scripts in C<--test-dir> will be run.
[XXX Not sure whether to have subdirectories for tests and expected output and
to diff them, or to use some other approach.]

=item C<package>

Package up all deployment and reversion scripts and write out a plan file.
Options:

=over

=item C<--tags-only>

Write the plan file with deployment targets listed under VCS tags, rather than
individual commits.

=item C<--destdir>

Specify a destination directory. The plan file and C<deploy>, C<revert>, and
C<test> directories will be written to it. Defaults to "package".

=back

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
