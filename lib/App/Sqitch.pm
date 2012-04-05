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

=head2 Terminology

=over

=item C<step>

A named unit of change. A step name must be used in the file names of its
corresponding deployment and a reversion scripts. It may also be used in a
test script file name.

=item C<tag>

A known deployment state with a list one or more steps that define the tag. A
tag also implies that steps from previous tags in the plan have been applied.
Think of it is a version number or VCS revision. A given point in the plan may
have one or more tags.

=item C<state>

The current state of the database. This is represented by the most recent tag
or tags deployed. If the state of the database is the same as the most recent
tag, then it is considered "up-to-date".

=item C<plan>

A list of one or more tags and associated steps that define the order of
deployment execution. Sqitch reads the plan to determine what steps to execute
to change the database from one state to another. The plan may be represented
by a L<Plan File> or by VCS history.

=item C<deploy>

The act of deploying database changes to reach a tagged deployment point.
Sqitch reads the plan, checks the current state of the database, and applies
all the steps necessary to change the state to the specified tag.

=item C<revert>

The act of reverting database changes to reach an earlier tagged deployment
point. Sqitch checks the current state of the database, reads the plan, and
applies reversion scripts for all steps to return the state to an earlier tag.

=back

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

=item C<config>

Set configuration options. By default, the options will be written to the
local configuration file, F<sqitch.ini>. Options:

=over

=item C<--get>

Get the value for a given key. Returns error code 1.

=item C<--unset>

Remove the line matching the key from config file.

=item C<--list>

List all variables set in config file.

=item C<--global>

For writing options: write to global F<~/.sqitch/config.ini> file rather than
the local F<sqitch.ini>.

For reading options: read only from global F<~/.sqitch/config.ini> rather
than from all available files.

=item C<--system>

For writing options: write to system-wide F<$prefix/etc/sqitch.ini> file
rather than the local F<sqitch.ini>.

For reading options: read only from system-wide F<$prefix/etc/sqitch.ini>
rather than from all available files.

=item C<--config-file>

Use the given config file.

=back

=item C<package>

Package up all deployment and reversion scripts and write out a plan file.
Options:

=over

=item C<--from>

Tag to start the plan from. All tags and steps prior to that tag will not be
included in the plan, and their change scripts Will be omitted from the
package directory. Useful if you've rejiggered your deployment steps to start
from a point later in your VCS history than the beginning of time.

=item C<--to>

Tag with which to end the plan. No steps or tags after that tag will be
included in the plan, and their change scripts will be omitted from the
package directory.

=item C<--tags-only>

Write the plan file with deployment targets listed under VCS tags, rather than
individual commits.

=item C<--destdir>

Specify a destination directory. The plan file and C<deploy>, C<revert>, and
C<test> directories will be written to it. Defaults to "package".

=back

=back

=head1 Plan File

A plan file describes the deployment tags and scripts to be run against a
database. In general, if you use a VCS, you probably won't need a plan file,
since your VCS history should be able to provide all the information necessary
to derive a deployment plan. However, if you really do need to maintain a plan
file by hand, or just want to better understand the file as output by the
C<package> command, read on.

=head2 Format

The contents of the plan file are plain text encoded as UTF-8. It is divided
up into sections that denote deployment states. Each state has a bracketed,
space-delimited list of one or more tags to identify it, followed by any
number of deployment steps. Here's an example of a plan file with a single
state and a single step:

 [alpha]
 users_table

The state has one tag, named "alpha", and one step, named "users_table".
A state may of course have many steps. Here's an expansion:

 [root alpha]
 users_table
 insert_user
 update_user
 delete_user

This state has two tags, "root" and "alpha", and four steps, "users_table",
"insert_user", "update_user", and "delete_user".

Most plans will have multiple states. Here's a longer example with three
states:

 [root alpha]
 users_table
 insert_user
 update_user
 delete_user

 [beta]
 widgets_table
 list_widgets

 [gamma]
 ftw

Using this plan, to deploy to the "beta" tag, the "root"/"alpha" state steps
must be deployed, as must the "beta" steps. To then deploy to the "gamma" tag,
the "ftw" step must be deployed. If you then choose to revert to the "alpha"
tag, then the "gamma" step ("ftw") and all of the "beta" steps will be
reverted in reverse order.

Using this model, steps cannot be repeated between states. One can repeat
them, however, if the contents for a file in a given tag can be retrieved from
a VCS. An example:

 [alpha]
 users_table

 [beta]
 add_widget
 widgets_table

 [gamma]
 add_user

 [44ba615b7813531f0acb6810cbf679791fe57bf2]
 widgets_created_at

 [HEAD epsilon master]
 add_widget

This example is derived from a Git log history. Note that the "add_widget"
step is repeated under the state tagged "beta" and under the last state.
Sqitch will notice the repetition when it parses this file, and then, if it is
applying all changes, will fetch the version of the file as of the "beta" tag
and apply it at that step, and then, when it gets to the last tag, retrieve
the deployment file as of its tags and apply it. This works in reverse, as
well, as long as the changes in this file are always
L<idempotent|http://en.wikipedia.org/wiki/Idempotence>.

=head2 Grammar

Here is the EBNF Grammar for the plan file:

  plan-file   = { <state> | <empty-line> | <comment> }* ;

  state       = <tags> <steps> ;

  tags        = "[" <taglist> "]" <line-ending> ;
  taglist     = <name> | <name> <white-space> <taglist> ;

  steps       = { <step> | <empty-line> | <line-ending> }* ;
  step        = <name> <line-ending> ;

  empty-line  = [ <white-space> ] <line-ending> ;
  line-ending = [ <comment> ] <EOL> ;
  comment     = [ <white-space> ] "#" [ <string> ] ;

  name        = ? non-white space characters ? ;
  white-space = ? white space characters ? ;
  string      = ? non-EOL characters ? ;

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
