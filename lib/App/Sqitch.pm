package App::Sqitch;

use v5.10;
use strict;
use warnings;
use utf8;
use Getopt::Long;
use Hash::Merge qw(merge);
use Path::Class;
use Config;
use App::Sqitch::Command;
use parent 'Class::Accessor::Fast';

our $VERSION = '0.10';

__PACKAGE__->mk_ro_accessors(qw(
    plan_file
    engine
    client
    db_name
    username
    host
    port
    sql_dir
    deploy_dir
    revert_dir
    test_dir
    extension
    dry_run
    config
    verbosity
));

sub go {
    my $class = shift;

    # 1. Split command and options.
    my ($core_args, $cmd, $cmd_args) = $class->_split_args(@ARGV);

    # 2. Parse core options.
    my $core_opts = $class->_parse_core_opts($core_args);

    # 3. Load config.
    my $config = $class->_load_config;

    # 4. Instantiate Sqitch.
    my $sqitch = $class->new(merge $core_opts, $config->{core});
    $sqitch->{config} = $config;

    # 5. Instantiate the command object.
    my $command = App::Sqitch::Command->load({
        sqitch  => $sqitch,
        command => $cmd,
        config  => $config->{$cmd},
        args    => $cmd_args,
    });

    # 6. Execute command.
    return $command->execute(@{ $cmd_args }) ? 0 : 2;
}

sub new {
    my $class = shift;
    my %p = %{ +shift || {} };
    $p{verbosity} //= 0;
    return $class->SUPER::new(\%p);
}

# XXX Not sure if I want to standardize these or not, so not yet.
# sub username {
#     shift->{username} // $ENV{SQITCH_USER} // $ENV{USER};
# }

# sub db_name {
#     my $self = shift;
#     $self->{db_name} // $ENV{SQITCH_DBNAME} // $self->username;
# }

# sub host {
#     shift->{host} // $ENV{SQITCH_HOST};
# }

# sub port {
#     shift->{port} // $ENV{SQITCH_PORT};
# }

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

sub _user_config_root {
    return dir $ENV{SQITCH_USER_CONFIG_ROOT} if $ENV{SQITCH_USER_CONFIG_ROOT};

    require File::HomeDir;
    my $homedir = File::HomeDir->my_home
        or croak("Could not determine home directory");

    return dir($homedir)->subdir('.sqitch');
}

sub _system_config_root {
    return dir $ENV{SQITCH_SYSTEM_CONFIG_ROOT} if $ENV{SQITCH_SYSTEM_CONFIG_ROOT};
    return dir $Config{prefix}, 'etc';
}

sub _load_config {
    my $self = shift;
    my $hm = Hash::Merge->new;
    return $hm->merge(
        $self->_read_ini('sqitch.ini'),
        $hm->merge(
            $self->_read_ini( $self->_user_config_root->file('config.ini') ),
            $self->_read_ini( $self->_system_config_root->file('sqitch.ini') )
        )
    );
}

sub editor {
    my $self = shift;
    return $self->{editor} ||= $ENV{SQITCH_EDITOR} || $ENV{EDITOR}
        || ($^O eq 'MSWin32' ? 'notepad.exe' : 'vi');
}

sub _read_ini {
    my ($self, $file) = @_;
    return {} unless -f $file;
    require Config::INI::Reader;
    # XXX Should we get a share lock on the file, first? Probably not...
    return Config::INI::Reader->read_file($file);
}

1;

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
