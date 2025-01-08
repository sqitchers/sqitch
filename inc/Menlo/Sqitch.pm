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
        Data-Compare
        Devel-CheckLib
        Devel-Hide
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
        ExtUtils-Manifest
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
        MIME-Charset
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
        Pod-Markdown
        Safe
        Search-Dict
        Sub-Uplevel
        Term-Size-Any
        Term-Size-Perl
        Term-Table
        Test
        Test-Exception
        Test-Fatal
        Test-Harness
        Test-Pod
        Test-Pod-Coverage
        Test-Simple
        Test-Version
        Text-Glob
        Tie-File
        Tie-Handle-Offset
        TimeDate
        Unicode-LineBreak
        Unicode-UTF8
        WWW-RobotRules
        Win32-ShellQuote
        YAML
        YAML-LibYAML
        YAML-Syck
        bignum
        inc-latest
        libwww-perl
        local-lib

Runtime-only dependencies
        Algorithm-Backoff
        B-Hooks-EndOfScope
        Class-Data-Inheritable
        Class-Inspector
        Class-Method-Modifiers
        Class-Singleton
        Class-XSAccessor
        Clone-Choose
        Config-GitLike
        DBD-Firebird
        DBD-MariaDB
        DBD-ODBC
        DBD-Oracle
        DBD-Pg
        DBD-SQLite
        Data-OptList
        DateTime
        DateTime-Locale
        DateTime-TimeZone
        Devel-Caller
        Devel-LexAlias
        Devel-StackTrace
        Eval-Closure
        Exception-Class
        Exporter-Tiny
        File-ShareDir
        Hash-Merge
        IO-Pager
        IPC-System-Simple
        List-MoreUtils
        List-MoreUtils-XS
        MRO-Compat
        Module-Implementation
        Module-Runtime
        Moo
        MooX-Types-MooseLike
        MySQL-Config
        Package-Stash
        Package-Stash-XS
        PadWalker
        Params-ValidationCompiler
        Path-Class
        Ref-Util
        Ref-Util-XS
        Regexp-Util
        Role-Tiny
        Specio
        String-Formatter
        Sub-Exporter
        Sub-Exporter-Progressive
        Sub-Install
        Sub-Quote
        Template-Tiny
        Template-Toolkit
        Term-ANSIColor
        Throwable
        Type-Tiny
        Type-Tiny-XS
        URI-Nested
        URI-db
        libintl-perl
        namespace-autoclean
        namespace-clean
        strictures

Overlapping dependencies
        Carp
        Clone
        DBI
        Data-Dumper
        Digest-SHA
        Encode
        Encode-Locale
        Env
        Exporter
        File-Path
        File-Temp
        File-Which
        Getopt-Long
        IO
        IPC-Run3
        MIME-Base32
        MIME-Base64
        Params-Util
        PathTools
        Perl-OSType
        PerlIO-utf8_strict
        Pod-Escapes
        Pod-Parser
        Pod-Perldoc
        Pod-Simple
        Pod-Usage
        Scalar-List-Utils
        Socket
        Storable
        String-ShellQuote
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
        parent
        podlators
        version
