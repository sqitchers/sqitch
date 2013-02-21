package Module::Build::Sqitch;

use strict;
use warnings;
use Module::Build 0.35;
use parent 'Module::Build';

__PACKAGE__->add_property($_) for qw(etcdir installed_etcdir);

sub new {
    my ( $class, %p ) = @_;
    if ($^O eq 'MSWin32') {
        my $recs = $p{recommends} ||= {};
        $recs->{$_} = 0 for qw(
            Win32
            Win32::Console::ANSI
            Win32API::Net
        );
        $p{requires}{'Win32::Locale'} = 0;
        $p{requires}{'Win32::ShellQuote'} = 0;
    }
    my $self = $class->SUPER::new(%p);
    $self->add_build_element('etc');
    $self->add_build_element('mo');
    $self->add_build_element('sql');
    return $self;
}

sub _getetc {
    my $self = shift;
    # Prefer the user-specified directory.
    if (my $etc = $self->etcdir) {
        return $etc;
    }

    # Use a directory unde the install base (or prefix).
    my @subdirs = qw(etc sqitch);
    if ( my $dir = $self->prefix || $self->install_base ) {
        return File::Spec->catdir( $dir, @subdirs );
    }

    # Go under Perl's prefix.
    return File::Spec->catdir( $Config::Config{prefix}, @subdirs );
}

sub process_etc_files {
    my $self = shift;
    my $etc  = $self->_getetc;
    $self->install_path( etc => $etc );
    for my $file ( @{ $self->rscan_dir( 'etc', sub { -f && !/\.\#/ } ) } ) {
        $file = $self->localize_file_path($file);

        # Remove leading `etc/` to get path relative to $etc.
        my ($vol, $dirs, $fn) = File::Spec->splitpath($file);
        my (undef, @segs) = File::Spec->splitdir($dirs);
        my $rel = File::Spec->catpath($vol, File::Spec->catdir(@segs), $fn);

        # Append .default if file already exists at its ultimate destination.
        my $dest = -e File::Spec->catfile($etc, $rel) ? "$file.default" : $file;

        $self->copy_if_modified(
            from => $file,
            to   => File::Spec->catfile( $self->blib, $dest )
        );
    }
}

sub process_pm_files {
    my $self = shift;
    my $ret  = $self->SUPER::process_pm_files(@_);
    my $pm   = File::Spec->catfile(qw(blib lib App Sqitch Config.pm));
    my $etc  = $self->installed_etcdir || $self->_getetc;

    $self->do_system(
        $self->perl, '-i.bak', '-pe',
        qq{s{my \\\$SYSTEM_DIR = undef}{my \\\$SYSTEM_DIR = q{$etc}}},
        $pm,
    );
    unlink "$pm.bak";

    return $ret;
}

1;
