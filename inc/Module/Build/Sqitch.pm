package Module::Build::Sqitch;

use strict;
use warnings;
use Module::Build 0.35;
use base 'Module::Build';
use IO::File ();
use File::Spec ();
use Config ();
use File::Path ();
use File::Copy ();

__PACKAGE__->add_property($_) for qw(etcdir installed_etcdir);
__PACKAGE__->add_property(with => []);

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
        $p{requires}{'DateTime::TimeZone::Local::Win32'} = 0;
        $p{build_requires}{'Config::GitLike'} = '1.15';
    }
    my $self = $class->SUPER::new(%p);
    $self->add_build_element('etc');
    $self->add_build_element('mo');
    $self->add_build_element('sql');
    return $self;
}

sub _getetc {
    my $self = shift;
    my $prefix;

    if ($self->installdirs eq 'site') {
        $prefix = $Config::Config{siteprefix} // $Config::Config{prefix};
    } elsif ($self->installdirs eq 'vendor') {
        $prefix = $Config::Config{vendorprefix} // $Config::Config{siteprefix} // $Config::Config{prefix};
    } else {
        $prefix = $Config::Config{prefix};
    }

    # Prefer the user-specified directory.
    if (my $etc = $self->etcdir) {
        return $etc;
    }

    # Use a directory under the install base (or prefix).
    my @subdirs = qw(etc sqitch);
    if ( my $dir = $self->install_base || $self->prefix ) {
        return File::Spec->catdir( $dir, @subdirs );
    }

    # Go under Perl's prefix.
    return File::Spec->catdir( $prefix, @subdirs );
}

sub ACTION_move_old_templates {
    my $self = shift;
    $self->depends_on('build');

    # First, rename existing etc dir templates; They were moved in v0.980.
    my $notify = 0;
    my $tmpl_dir = File::Spec->catdir(
        ( $self->destdir ? $self->destdir : ()),
        $self->_getetc,
        'templates'
    );
    if (-e $tmpl_dir && -d _) {
        # Scan for old templates, but only if we can read the directory.
        if (opendir my $dh, $tmpl_dir) {
            while (my $bn = readdir $dh) {
                next unless $bn =~ /^(deploy|verify|revert)[.]tmpl([.]default)?$/;
                my ($action, $default) = ($1, $2);
                my $file = File::Spec->catfile($tmpl_dir, $bn);
                if ($default) {
                    $self->log_verbose("Unlinking $file\n");
                    # Just unlink default files.
                    unlink $file;
                    next;
                }
                # Move action templates to $action/pg.tmpl and $action/sqlite.tmpl.
                my $action_dir = File::Spec->catdir($tmpl_dir, $action);
                File::Path::mkpath($action_dir) or die;
                for my $engine (qw(pg sqlite)) {
                    my $dest = File::Spec->catdir($action_dir, "$engine.tmpl");
                    $self->log_info("Copying old $bn to $dest\n");
                    File::Copy::copy($file, $dest)
                        or die "Cannot copy('$file', '$dest'): $!\n";
                }

                $self->log_verbose("Unlinking $file\n");
                unlink $file;
                $notify = 1;
            }
        }
    }

    # If we moved any files, nofify the user that custom templates will need
    # to be updated, too.
    if ($notify) {
        $self->log_warn(q{
            #################################################################
            #                         WARNING                               #
            #                                                               #
            # As of v0.980, the location of script templates has changed.   #
            # The system-wide templates have been moved to their new        #
            # locations as described above. However, user-specific          #
            # templates have not been moved.                                #
            #                                                               #
            # Please inform all users that any custom Sqitch templates in   #
            # their ~/.sqitch/templates directories must be moved into      #
            # subdirectories using the appropriate engine name (pg, sqlite, #
            # or oracle) as follows:                                        #
            #                                                               #
            #             deploy.tmpl -> deploy/$engine.tmpl                #
            #             revert.tmpl -> revert/$engine.tmpl                #
            #             verify.tmpl -> verify/$engine.tmpl                #
            #                                                               #
            #################################################################
        } . "\n");
    }
}

sub ACTION_install {
    my ($self, @params) = @_;
    $self->depends_on('move_old_templates');
    $self->SUPER::ACTION_install(@_);
}

sub process_etc_files {
    my $self = shift;
    my $etc  = $self->_getetc;
    $self->install_path( etc => $etc );

    if (my $ddir = $self->destdir) {
        # Need to search the final destination directory.
        $etc = File::Spec->catdir($ddir, $etc);
    }

    for my $file ( @{ $self->rscan_dir( 'etc', sub { -f && !/\.\#/ } ) } ) {
        $file = $self->localize_file_path($file);

        # Remove leading `etc/` to get path relative to $etc.
        my ($vol, $dirs, $fn) = File::Spec->splitpath($file);
        my (undef, @segs) = File::Spec->splitdir($dirs);
        my $rel = File::Spec->catpath($vol, File::Spec->catdir(@segs), $fn);

        my $dest = $file;

        # Append .default if file already exists at its ultimate destination
        # or if it exists with an old name (to be moved by move_old_templates).
        if ( -e File::Spec->catfile($etc, $rel) || (
            $segs[0] eq 'templates'
                && $fn =~ /^(?:pg|sqlite)[.]tmpl$/
                && -e File::Spec->catfile($etc, 'templates', "$segs[1].tmpl")
        ) ) {
            $dest .= '.default';
        }

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
        qq{s{my \\\$SYSTEM_DIR = undef}{my \\\$SYSTEM_DIR = q{\Q$etc\E}}},
        $pm,
    );
    unlink "$pm.bak";

    return $ret;
}

sub fix_shebang_line {
    my $self = shift;
    # Noting to do before after 5.10.0.
    return $self->SUPER::fix_shebang_line(@_) if $] > 5.010000;

    # Remove -C from the shebang line.
    for my $file (@_) {
        my $FIXIN = IO::File->new($file) or die "Can't process '$file': $!";
        local $/ = "\n";
        chomp(my $line = <$FIXIN>);
        next unless $line =~ s/^\s*\#!\s*//;     # Not a shebang file.

        my ($cmd, $arg) = (split(' ', $line, 2), '');
        next unless $cmd =~ /perl/i && $arg =~ s/ -C\w+//;

        # We removed -C; write the file out.
        my $FIXOUT = IO::File->new(">$file.new")
            or die "Can't create new $file: $!\n";
        local $\;
        undef $/; # Was localized above
        print $FIXOUT "#!$cmd $arg", <$FIXIN>;
        close $FIXIN;
        close $FIXOUT;

        rename($file, "$file.bak")
            or die "Can't rename $file to $file.bak: $!";

        rename("$file.new", $file)
            or die "Can't rename $file.new to $file: $!";

        $self->delete_filetree("$file.bak")
            or $self->log_warn("Couldn't clean up $file.bak, leaving it there");
    }

    # Back at it now.
    return $self->SUPER::fix_shebang_line(@_);
}

sub ACTION_bundle {
    my ($self, @params) = @_;
    my $base = $self->install_base or die "No --install_base specified\n";
    SHHH: {
        local $SIG{__WARN__} = sub {}; # Menlo has noisy warnings.
        local $ENV{PERL_CPANM_OPT}; # Override cpanm options.
        require Menlo::Sqitch;
        my $feat = $self->with || [];
        $feat = [$feat] unless ref $feat;
        my $app = Menlo::Sqitch->new(
            quiet          => $self->quiet,
            verbose        => $self->verbose,
            notest         => 1,
            self_contained => 1,
            install_types  => [qw(requires recommends)],
            local_lib      => File::Spec->rel2abs($base),
            pod2man        => undef,
            installdeps    => 1,
            features       => { map { $_ => 1 } @{ $feat } },
            argv           => ['.'],
        );
        die "Error installing modules: $@\n" if $app->run;
        die "Error removing build modules: $@\n"
            unless $app->remove_build_dependencies;
    }

    # Install Sqitch.
    $self->depends_on('install');

    # Delete unneeded files.
    $self->delete_filetree(File::Spec->catdir($base, qw(lib perl5 Test)));
    $self->delete_filetree(File::Spec->catdir($base, qw(bin)));
    for my $file (@{ $self->rscan_dir($base, qr/[.](?:meta|packlist)$/) }) {
        $self->delete_filetree($file);
    }

    # Install sqitch script using FindBin.
    $self->_copy_findbin_script;

    # Delete empty directories.
    File::Find::finddepth(sub{rmdir},$base);
}

sub _copy_findbin_script {
    my $self = shift;
    # XXX Switch to lib/perl5.
    my $bin = $self->install_destination('script');
    my $script = File::Spec->catfile(qw(bin sqitch));
    my $dest = File::Spec->catfile($bin, 'sqitch');
    my $result = $self->copy_if_modified($script, $bin, 'flatten') or return;
    $self->fix_shebang_line($result) unless $self->is_vmsish;
    $self->_set_findbin($result);
    $self->make_executable($result);
}

sub _set_findbin {
    my ($self, $file) = @_;
    local $^I = '';
    local @ARGV = ($file);
    while (<>) {
        s{^BEGIN}{use FindBin;\nuse lib "\$FindBin::Bin/../lib/perl5";\nBEGIN};
        print;
    }
}
