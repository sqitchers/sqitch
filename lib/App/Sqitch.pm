package App::Sqitch;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Getopt::Long;
use Hash::Merge qw(merge);
use Path::Class;
use Config;
use App::Sqitch::Config;
use App::Sqitch::Command;
use Moose;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

our $VERSION = '0.11';

has plan_file => (is => 'ro', required => 1, default => sub {
    file 'sqitch.plan';
});

has _engine => (is => 'ro', isa => enum [qw(pg mysql sqlite)]);
has engine => (is => 'ro', isa => 'Maybe[App::Sqitch::Engine]', lazy => 1, default => sub {
    my $self = shift;
    my $name = $self->_engine or return;
    require App::Sqitch::Engine;
    App::Sqitch::Engine->load({sqitch => $self, engine => $name});
});

# Attributes useful to engines; no defaults.
has client   => (is => 'ro', isa => 'Str');
has db_name  => (is => 'ro', isa => 'Str');
has username => (is => 'ro', isa => 'Str');
has host     => (is => 'ro', isa => 'Str');
has port     => (is => 'ro', isa => 'Int');

has sql_dir => (is => 'ro', required => 1, lazy => 1, default => sub { dir 'sql' });

has deploy_dir => (is => 'ro', required => 1, lazy => 1, default => sub {
    shift->sql_dir->subdir('deploy');
});

has revert_dir => (is => 'ro', required => 1, lazy => 1, default => sub {
    shift->sql_dir->subdir('revert');
});

has test_dir => (is => 'ro', required => 1, lazy => 1, default => sub {
    shift->sql_dir->subdir('test');
});

has extension => (is => 'ro', isa => 'Str', default => 'sql');

has dry_run => (is => 'ro', isa => 'Bool', required => 1, default => 0);

has verbosity => (is => 'ro', required => 1, default => 1);

has config => (is => 'ro', isa => 'App::Sqitch::Config', lazy => 1, default => sub {
    App::Sqitch::Config->new
});

has editor => (is => 'ro', lazy => 1, default => sub {
    return $ENV{SQITCH_EDITOR} || $ENV{EDITOR} || (
        $^O eq 'MSWin32' ? 'notepad.exe' : 'vi'
    );
});

sub go {
    my $class = shift;

    # 1. Split command and options.
    my ($core_args, $cmd, $cmd_args) = $class->_split_args(@ARGV);

    # 2. Parse core options.
    my $core_opts = $class->_parse_core_opts($core_args);

    # 3. Load config.
    my $config = App::Sqitch::Config->new;

    # 4. Instantiate Sqitch.
    my $params = merge $core_opts, $config->get_section(section => 'core');
    $params->{_engine} = delete $params->{engine} if $params->{engine};
    my $sqitch = $class->new($params);
    $sqitch->{config} = $config;

    # 5. Instantiate the command object.
    my $command = App::Sqitch::Command->load({
        sqitch  => $sqitch,
        command => $cmd,
        config  => $config,
        args    => $cmd_args,
    });

    # 6. Execute command.
    return $command->execute(@{ $cmd_args }) ? 0 : 2;
}

sub _core_opts {
    return qw(
        plan-file=s
        engine=s
        client=s
        db-name|d=s
        username|user|u=s
        host=s
        port=i
        sql-dir=s
        deploy-dir=s
        revert-dir=s
        test-dir=s
        extension=s
        dry-run
        quiet
        verbose+
        help
        man
        version
    );
}

sub _split_args {
    my ($self, @args) = @_;

    my $cmd_at  = 0;
    my $add_one = sub { $cmd_at++ };
    my $add_two = sub { $cmd_at += 2 };

    Getopt::Long::Configure(qw(bundling));
    Getopt::Long::GetOptionsFromArray(
        [@args],
        # Halt processing on on first non-option, which will be the command.
        '<>' => sub { die '!FINISH' },
        # Count how many args we've processed until we die.
        map { $_ => m/=/ ? $add_two : $add_one } $self->_core_opts
    ) or $self->_pod2usage;

    # Splice the command and its options out of the arguments.
    my ($cmd, @cmd_opts) = splice @args, $cmd_at;
    return \@args, $cmd, \@cmd_opts;
}

sub _parse_core_opts {
    my ($self, $args) = @_;
    my %opts;
    Getopt::Long::Configure(qw(bundling pass_through));
    Getopt::Long::GetOptionsFromArray($args, map {
        (my $k = $_) =~ s/[|=+:!].*//;
        $k =~ s/-/_/g;
        $_ => \$opts{$k};
    } $self->_core_opts) or $self->_pod2usage;

    # Handle documentation requests.
    $self->_pod2usage('-exitval' => 0, '-verbose' => 2) if delete $opts{man};
    $self->_pod2usage('-exitval' => 0                 ) if delete $opts{help};

    # Handle version request.
    if (delete $opts{version}) {
        require File::Basename;
        my $fn = File::Basename::basename($0);
        print $fn, ' (', __PACKAGE__, ') ', __PACKAGE__->VERSION, $/;
        exit;
    }

    # Normalize the options (remove undefs) and return.
    $opts{verbosity} = delete $opts{verbose};
    delete $opts{$_} for grep { !defined $opts{$_} } keys %opts;
    return \%opts;
}

sub _pod2usage {
    shift;
    require Pod::Usage;
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Synopsis|Usage|Options))',
        '-exitval'  => 2,
        @_
    );
}

__PACKAGE__->meta->make_immutable;
no Moose;

__END__

=head1 Name

App::Sqitch - VCS-powered SQL change management

=head1 Synopsis

  user App::Sqitch;
  exit App::Sqitch->go;

=head1 Description

This module provides the implementation for L<sqitch>. You probably want to
read L<its documentation|sqitch>, or L<the tutorial|sqitchtutorial>. Unless
you want to hack on Sqitch itself, or provide support for a new engine or
L<command|Sqitch::App::Command>. In which case, you will find this API
documentation useful.

=head1 Interface

=head2 Class Methods

=head3 C<go>

  App::Sqitch->go;

Called from C<sqitch>, this class method parses command-line options and
arguments in C<@ARGV>, parses the configuration file, constructs an
App::Sqitch object, constructs a command object, and runs it.

=head2 Constructor

=head3 C<new>

  my $sqitch = App::Sqitch->new(\%params);

Constructs and returns a new Sqitch object. The supported parameters include:

=over

=item C<plan_file>

=item C<engine>

=item C<client>

=item C<db_name>

=item C<username>

=item C<host>

=item C<port>

=item C<sql_dir>

=item C<deploy_dir>

=item C<revert_dir>

=item C<test_dir>

=item C<extension>

=item C<dry_run>

=item C<editor>

=item C<verbosity>

=back

=head2 Accessors

=head3 C<plan_file>

=head3 C<engine>

=head3 C<client>

=head3 C<db_name>

=head3 C<username>

=head3 C<host>

=head3 C<port>

=head3 C<sql_dir>

=head3 C<deploy_dir>

=head3 C<revert_dir>

=head3 C<test_dir>

=head3 C<extension>

=head3 C<dry_run>

=head3 C<editor>

=head3 C<config>

  my $config = $sqitch->config;

Returns the full configuration, combined from the project, user, and system
configuration files.

=head3 C<verbosity>

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
