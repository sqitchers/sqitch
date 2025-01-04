package Menlo::Sqitch;

use strict;
use warnings;
use base 'Menlo::CLI::Compat';

sub new {
    my %deps;
    while (<DATA>) {
        last if /^Build-only dependencies/;
    }
    while (<DATA>) {
        chomp;
        last unless s/^\s+//;
        $deps{$_} = 1;
    }
    shift->SUPER::new(
        @_,
        _remove   => [],
        _bld_deps => \%deps,
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
Build-only dependencies
        Alien-Build
        Alien-cmake3
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
        FFI-CheckLib
        File-Fetch
        File-Find-Rule
        File-Find-Rule-Perl
        File-HomeDir
        File-Listing
        File-ShareDir-Install
        File-Slurper
        File-chdir
        File-pushd
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
        IO-Compress-Brotli
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
        Path-Tiny
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
        Test-NoWarnings
        Test-Pod
        Test-Pod-Coverage
        Test-Simple
        Test-Version
        Text-Balanced
        Text-CSV_XS
        Text-Glob
        Text-Soundex
        Thread-Semaphore
        Tie-File
        Tie-Handle-Offset
        TimeDate
        Unicode-UTF8
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
        lib
        libwww-perl
        libxml-perl
        local-lib
        threads
        threads-shared

Runtime-only dependencies
        Algorithm-Backoff
        Class-Inspector
        Class-Singleton
        Clone-Choose
        Config-GitLike
        DBD-Firebird
        DBD-ODBC
        DBD-Oracle
        DBD-Pg
        DBD-MariaDB
        Data-OptList
        DateTime
        DateTime-Locale
        DateTime-TimeZone
        Exporter-Tiny
        File-ShareDir
        Hash-Merge
        IO-Pager
        IPC-System-Simple
        List-MoreUtils
        List-MoreUtils-XS
        Moo
        MooX-Types-MooseLike
        MySQL-Config
        Path-Class
        Ref-Util-XS
        Regexp-Util
        String-Formatter
        Sub-Exporter
        Sub-Install
        Template-Tiny
        Template-Toolkit
        Term-ANSIColor
        Throwable
        Type-Tiny
        Type-Tiny-XS
        URI-Nested
        URI-db
        libintl-perl
        strictures

Overlapping dependencies
        B-Hooks-EndOfScope
        Carp
        Class-Data-Inheritable
        Class-Method-Modifiers
        Class-XSAccessor
        Clone
        DBD-SQLite
        DBI
        Data-Dumper
        Devel-Caller
        Devel-LexAlias
        Devel-StackTrace
        Digest-SHA
        Encode
        Encode-Locale
        Env
        Eval-Closure
        Exception-Class
        Exporter
        File-Path
        File-Temp
        File-Which
        Getopt-Long
        IO
        IPC-Run3
        MIME-Base64
        MRO-Compat
        Module-Implementation
        Module-Runtime
        Package-Stash
        Package-Stash-XS
        PadWalker
        Params-Util
        Params-ValidationCompiler
        PathTools
        Perl-OSType
        PerlIO-utf8_strict
        Pod-Escapes
        Pod-Parser
        Pod-Perldoc
        Pod-Simple
        Pod-Usage
        Ref-Util
        Role-Tiny
        Scalar-List-Utils
        Socket
        Specio
        Storable
        String-ShellQuote
        Sub-Exporter-Progressive
        Sub-Identify
        Sub-Quote
        TermReadKey
        Text-ParseWords
        Text-Tabs+Wrap
        Time-HiRes
        Time-Local
        Try-Tiny
        URI
        XSLoader
        base
        constant
        if
        libnet
        namespace-autoclean
        namespace-clean
        parent
        podlators
        version
