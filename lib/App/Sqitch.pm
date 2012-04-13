package App::Sqitch;

use v5.10;
use strict;
use warnings;
use utf8;
use Getopt::Long;
use parent 'Class::Accessor::Fast';

__PACKAGE__->mk_ro_accessors(qw(
    plan_file
    engine
));

our $VERSION = '0.10';

sub go {
    my $class = shift;
    # 1. Split command and options.
    my ($core_args, $cmd, $cmd_args) = $class->_split_args(@ARGV);
    # 2. Parse core options.
    my $core_opts = $class->_parse_core_opts($core_args);
    # 3. Instantiate command.
    # 3. Parse command options.
    # 4. Instantiate and run command.
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
        (my $k = $_) =~ s/[|=+:].*//;
        $k =~ s/-/_/g;
        $_ => \$opts{$k},
    } $self->_core_opts) or $self->_pod2usage;

    # Handle documentation requests.
    $self->_pod2usage('-exitval' => 0, '-sections' => '.+') if delete $opts{man};
    $self->_pod2usage('-exitval' => 0)                      if delete $opts{help};

    # Handle version request.
    if (delete $opts{version}) {
        require File::Basename;
        my $fn = File::Basename::basename($0);
        print $fn, ' (', __PACKAGE__, ') ', __PACKAGE__->VERSION, $/;
        exit;
    }

    # Return the options.
    return \%opts;
}

sub _pod2usage {
    shift;
    require Pod::Usage;
    Pod::Usage::pod2usage(
        '-verbose'  => 99,
        '-sections' => '(?i:(Usage|Options))',
        '-exitval'  => 1,
        @_
    );
}

1;

__END__

=head1 Name

App::Sqitch - VCS-powered SQL change management

=head1 Synopsis

  user App::Sqitch;
  exit App::Sqitch->go;

=head1 Description

This module provides the implementation for L<sqitch>. You probably want
to read L<its documentation|sqitch>.

=head1 Interface

=head2 Class Methods

=head3 C<go>

  App::Sqitch->go;

Called from C<sqitch>, this class method parses command-line options and
arguments in C<@ARGV>, parses the configuration file, constructs an
App::Sqitch object, constructs a command object, and runs it.

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
