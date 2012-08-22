package Module::Build::Sqitch;

use strict;
use warnings;
use base 'Module::Build';

sub new {
    my ( $class, %p ) = @_;
    if ($^O eq 'MSWin32') {
        my $recs = $p{recommends} ||= {};
        $recs->{$_} = 0 for qw(
            Win32
            Win32::Console::ANSI
            Win32API::Net
        );
    }
    my $self = shift->SUPER::new(%p);
    $self->add_build_element('etc');
    $self->add_build_element('sql');
    return $self;
}

sub _path_to {
    my $self = shift;
    if ( my $dir = $self->prefix || $self->install_base ) {
        return File::Spec->catdir( $dir, @_ );
    }

    return File::Spec->catdir( $Config::Config{prefix}, @_, 'sqitch' );
}

sub process_etc_files {
    my $self = shift;
    my $etc  = $self->_path_to('etc');
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
    my $etc  = $self->_path_to('etc');

    $self->do_system(
        $self->perl, '-i.bak', '-pe',
        qq{s{my \\\$SYSTEM_DIR = undef}{my \\\$SYSTEM_DIR = q{$etc}}},
        $pm,
    );
    unlink "$pm.bak";

    return $ret;
}

1;
