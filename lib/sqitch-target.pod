=head1 Name

sqitch-target - Mange set of target databases

=head1 Synopsis

  sqitch target [-v | --verbose]
  sqitch target add [-s <property>=<value> ...] <name> <uri>
  sqitch target set-uri <name> <newuri>
  sqitch target set-registry <name> <registry>
  sqitch target set-client <name> <client>
  sqitch target set-top-dir <name> <directory>
  sqitch target set-plan-file <name> <file>
  sqitch target set-deploy-dir <name> <directory>
  sqitch target set-revert-dir <name> <directory>
  sqitch target set-verify-dir <name> <directory>
  sqitch target set-extension <name> <extension>
  sqitch target remove <name>
  sqitch target rename <old> <new>
  sqitch target show <name>

=head1 Description

Manage the set of databases ("targets") you deploy to. Each target may have a
number of properties:

=over

=item C<uri>

The L<database connection URI|URI::db> for the target. Required. Its format is:

  db:engine:[dbname]
  db:engine:[//[user[:password]@][host][:port]/][dbname][?params][#fragment]

Some examples:

=over

=item C<db:sqlite:widgets.db>

=item C<db:pg://dba@example.net/blanket>

=item C<db:mysql://db.example.com/>

=item C<db:firebird://localhost//tmp/test.fdb>

=back

See the L<DB URI Draft|https://github.com/theory/uri-db> for details.

=item C<registry>

The name of the registry schema or database. The default is C<sqitch>.

=item C<client>

The command-line client to use. If not specified, each engine looks in the OS
Path for an appropriate client.

=item C<top_dir>

The path to the top directory for the target. This directory generally
contains the plan file and subdirectories for deploy, revert, and verify
scripts. The default is F<.>, the current directory.

=item C<plan_file>

The plan file to use for this target. The default is C<$top_dir/sqitch.plan>.

=item C<deploy_dir>

The path to the deploy directory for the target. This directory contains all
of the deploy scripts referenced by changes in the C<plan_file>. The default
is C<$top_dir/deploy>.

=item C<revert_dir>

The path to the revert directory for the target. This directory contains all
of the revert scripts referenced by changes in the C<plan_file>. The default
is C<$top_dir/revert>.

=item C<verify_dir>

The path to the verify directory for the target. This directory contains all
of the verify scripts referenced by changes in the C<plan_file>. The default
is C<$top_dir/verify>.

=item C<extension>

The file name extension to append to change names to create script file names.
The default is C<sql>.

=back

Each of these overrides the corresponding engine-specific configuration -- for
example, the C<core.$engine.uri>, C<core.$engine.registry>,
C<core.$engine.client> L<config|sqitch-config> options.

=head1 Options

=over

=item C<-v>

=item C<--verbose>

Be a little more verbose and show remote URI after name.

=item C<-s>

=item C<--set>

  sqitch target add foo uri=db:pg:try -s top_dir=db -s registry=meta

Set a target property key/value pair. May be specified multiple times. Used
only by the C<add> action. Supported keys are:

=over

=item C<registry>

=item C<client>

=item C<top_dir>

=item C<plan_file>

=item C<deploy_dir>

=item C<revert_dir>

=item C<verify_dir>

=item C<extension>

=back

=back

=head1 Actions

With no arguments, shows a list of existing targets. Several actions are
available to perform operations on the targets.

=head2 C<add>

Add a target named C<< <name> >> for the database at C<< <uri> >>. The
C<--set> option specifies target-specific properties.

=head2 C<set-uri>

Set the URI for target C<< <name> >>.

=head2 C<set-registry>

Set the registry for target C<< <name> >>.

=head2 C<set-client>

Set the client for target C<< <name> >>.

=head2 C<set-top-dir>

Set the top directory for target C<< <name> >>.

=head2 C<set-plan-file>

Set the plan file for target C<< <name> >>.

=head2 C<set-deploy-dir>

Set the deploy directory for target C<< <name> >>.

=head2 C<set-revert-dir>

Set the revert directory for target C<< <name> >>.

=head2 C<set-verify-dir>

Set the verify directory for target C<< <name> >>.

=head2 C<set-extension>

Set the extension for target C<< <name> >>.

=head2 C<remove>, C<rm>

Remove the target named C<< <name> >>.

=head2 C<rename>

Rename the remote named C<< <old> >> to C<< <new> >>.

=head2 C<show>

Gives some information about the remote C<< <name> >>, including the
associated URI, registry, and client. Specify multiple target names to see
information for each.

=head1 Configuration Variables

The targets are stored in the configuration file, but the command itself
currently relies on no configuration variables.

=head1 Sqitch

Part of the L<sqitch> suite.
