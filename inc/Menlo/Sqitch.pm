package Menlo::Sqitch;

use strict;
use warnings;
use base 'Menlo::CLI::Compat';

sub new {
    shift->SUPER::new(
        @_,
        _remove   => [],
        _bld_deps => { map { chomp; $_ => 1 } <DATA> },
    );
}

sub find_prereqs {
    my ($self, $dist) = @_;
    # Menlo defaults to config, test, runtime. We just want to bundle runtime.
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
    push @{ $self->{_remove} } => $module if $self->{_bld_deps}{$dname};
    $self->SUPER::save_meta(@_);
}

sub remove_build_dependencies {
    # Uninstall modules for distributions not actually needed to run Sqitch.
    my $self = shift;
    local $self->{force} = 1;
    my @fail;
    for my $mod (reverse @{ $self->{_remove} }) {
        $self->uninstall_module($mod) or push @fail, $mod;
    }
    return !@fail;
}

1;

# List of distirbutions that might be installed but are not actually needed to
# run Sqitch. Used to track unneeded installs so they can be removed by
# remove_build_dependencies().
#
# Data pasted from the report of build-only dependencies by
# dev/dependency_report.
__DATA__
AppConfig
Archive-Tar
Archive-Zip
CPAN
CPAN-Checksums
CPAN-Common-Index
CPAN-DistnameInfo
CPAN-Meta
CPAN-Meta-Check
CPAN-Meta-Requirements
CPAN-Meta-YAML
CPAN-Perl-Releases
Capture-Tiny
Class-Tiny
Compress-Bzip2
Compress-Raw-Bzip2
Compress-Raw-Lzma
Compress-Raw-Zlib
Config-AutoConf
DBD-CSV
Data-Compare
Date-Manip
Devel-CheckLib
Devel-GlobalDestruction
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
File-HomeDir
File-Listing
File-ShareDir-Install
File-Slurper
File-pushd
FindBin
HTML-Parser
HTML-Tagset
HTTP-CookieJar
HTTP-Cookies
HTTP-Date
HTTP-Message
HTTP-Negotiate
HTTP-Tiny
HTTP-Tinyish
IO-Compress
IO-Compress-Lzma
IO-HTML
IO-Socket-IP
IO-Socket-SSL
IO-Tty
IO-Zlib
IPC-Cmd
JSON-PP
LWP-MediaTypes
Locale-Maketext-Simple
Log-Dispatch
Log-Dispatch-FileRotate
Log-Log4perl
Math-Base-Convert
Math-BigInt
Math-BigRat
Math-Complex
Menlo
Menlo-Legacy
Module-Build
Module-CPANfile
Module-CoreList
Module-Load
Module-Load-Conditional
Module-Metadata
Module-Signature
Mozilla-CA
Mozilla-PublicSuffix
Net-HTTP
Net-Ping
Net-SSLeay
Number-Compare
Params-Check
Parse-PMFile
Perl-Tidy
Pod-Coverage
SQL-Statement
Safe
Search-Dict
Sub-Uplevel
Sys-Syslog
Test
Test-Exception
Test-Fatal
Test-Harness
Test-LeakTrace
Test-NoWarnings
Test-Pod
Test-Pod-Coverage
Test-Simple
Test-Version
Text-Balanced
Text-CSV_XS
Text-Glob
Text-Soundex
Tie-File
Tie-Handle-Offset
TimeDate
WWW-RobotRules
Win32-ShellQuote
XML-DOM
XML-Parser
XML-RegExp
YAML
YAML-LibYAML
YAML-Syck
bignum
inc-latest
libwww-perl
libxml-perl
local-lib
