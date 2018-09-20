package Menlo::Sqitch;

use strict;
use warnings;
use base 'Menlo::CLI::Compat';

sub new {
    shift->SUPER::new(
         @_,
        _remove => {},
        _bld_deps => { map { chomp; $_ => 1 } <DATA> },
    );
}

# Menlo defaults to config, test, runtime. We just want to bundle runtime.
sub find_prereqs {
    my ($self, $dist) = @_;
    $dist->{want_phases} = ['runtime'];
    return $self->SUPER::find_prereqs($dist);
}

sub configure {
    my $self = shift;
    my $cmd = $_[0];
    return $self->SUPER::configure(@_) if ref $cmd ne 'ARRAY';
    # Always use vendor install dirs. Hack for
    # https://github.com/miyagawa/cpanminus/issues/581.
    if ($cmd->[1] eq 'Makefile.PL') {
        push @{ $cmd } => 'INSTALLDIRS=vendor';
    } elsif ($cmd->[1] eq 'Build.PL') {
        push @{ $cmd } => '--installdirs', 'vendor';
    }
    return $self->SUPER::configure(@_);
}

sub save_meta {
    my $self = shift;
    my ($module, $dist) = @_;
    # Record if we've installed a build-only dependency.
    my $dname = $dist->{meta}{name};
    $self->{_remove}{ $dname } = $module if $self->{_bld_deps}{$dname};
    $self->SUPER::save_meta(@_);
}

1;

# Data pasted from the report of build-only dependencies by
# dev/dependency_report.
__DATA__
Archive-Tar
CGI
CPAN
CPAN-Common-Index
CPAN-DistnameInfo
CPAN-Meta
CPAN-Meta-Check
CPAN-Meta-Requirements
CPAN-Meta-YAML
Capture-Tiny
Class-Tiny
Compress-Raw-Bzip2
Compress-Raw-Zlib
Config-AutoConf
Devel-CheckLib
Devel-PPPort
Devel-Symdump
Digest
Digest-MD5
Dist-CheckConflicts
Dumpvalue
Expect
ExtUtils-CBuilder
ExtUtils-Config
ExtUtils-Constant
ExtUtils-Helpers
ExtUtils-Install
ExtUtils-InstallPaths
ExtUtils-MakeMaker
ExtUtils-MakeMaker-CPANfile
ExtUtils-ParseXS
File-Fetch
File-Find-Rule
File-Find-Rule-Perl
File-Listing
File-ShareDir-Install
File-Slurp-Tiny
File-pushd
HTML-Parser
HTML-Tagset
HTTP-CookieJar
HTTP-Cookies
HTTP-Daemon
HTTP-Date
HTTP-Message
HTTP-Negotiate
HTTP-Tiny
HTTP-Tinyish
IO-CaptureOutput
IO-Compress
IO-HTML
IO-Socket-IP
IO-Socket-SSL
IO-Tty
IO-Zlib
IPC-Cmd
IPC-Run
JSON-PP
LWP-MediaTypes
Locale-Maketext-Simple
Menlo
Menlo-Legacy
Mock-Config
Module-Build
Module-Build-Tiny
Module-CPANfile
Module-CoreList
Module-Load
Module-Load-Conditional
Module-Metadata
Mozilla-CA
Mozilla-PublicSuffix
Net-HTTP
Net-Ping
Net-SSLeay
Number-Compare
Params-Check
Parse-PMFile
Pod-Coverage
Readonly
Safe
Search-Dict
Sub-Uplevel
TermReadKey
Test
Test-Exception
Test-Fatal
Test-Harness
Test-LeakTrace
Test-Pod
Test-Pod-Coverage
Test-Simple
Test-Version
Text-Glob
Text-ParseWords
Tie-File
Tie-Handle-Offset
TimeDate
WWW-RobotRules
Win32-ShellQuote
YAML
inc-latest
libwww-perl
local-lib
