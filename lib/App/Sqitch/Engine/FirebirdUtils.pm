#
# Adapted from the FirebirdMaker.pm module of DBD::Firebird
#
package App::Sqitch::Engine::FirebirdUtils;
use strict;
use warnings;

use File::Which ();
use File::Spec::Functions qw(catfile catdir);
# and Win32::TieRegistry ;)

sub find_firebird_isql {

    # Try hard to return the full path to the Firebird ISQL utility tool

    my $os = $^O;

    my $isql_path;
    if ($os eq 'MSWin32' || $os eq 'cygwin') {
        $isql_path = locate_firebird_ms();
    }
    elsif ($os eq 'darwin') {
        # my $fb_res = '/Library/Frameworks/Firebird.framework/Resources';
        die "Not implemented.  Contributions are welcomed!\n";
    }
    else {
        # GNU/Linux and others
        $isql_path = locate_firebird();
    }

    return $isql_path;
}

sub locate_firebird {

    #-- Check if there is a isql-fb in the PATH

    if ( my $isql_bin = File::Which::which('isql-fb') ) {
        if ( check_if_is_fb_isql($isql_bin) ) {
            return $isql_bin;
        }
    }

    #-- Check if there is a fb_config in the PATH

    if ( my $fb_config = File::Which::which('fb_config') ) {
        my $fb_bin_path = qx(fb_config --bindir);
        chomp $fb_bin_path;
        foreach my $isql_bin (qw{fbsql isql-fb isql}) {
            my $isql_path = catfile($fb_bin_path, $isql_bin);
            if ( check_if_is_fb_isql($isql_path) ) {
                return $isql_path;
            }
        }
    }

    #-- Check in the standard home dirs

    my @bd = standard_fb_home_dirs();
    foreach my $home_dir (@bd) {
        if ( -d $home_dir ) {
            my $fb_bin_path = catdir($home_dir, 'bin');
            foreach my $isql_bin (qw{fbsql isql-fb isql}) {
                my $isql_path = catfile($fb_bin_path, $isql_bin);
                if ( check_if_is_fb_isql($isql_path) ) {
                    return $isql_path;
                }
            }
        }
    }

    #-- Last, maybe one of the ISQLs in the PATH is the right one...

    if ( my @isqls = File::Which::which('isql') ) {
        foreach my $isql_bin (@isqls) {
            if ( check_if_is_fb_isql($isql_bin) ) {
                return $isql_bin;
            }
        }
    }

    die "Unable to locate Firebird ISQL, please use the config command....";

    return;
}

sub check_if_is_fb_isql {
    my $cmd = shift;
    if ( -f $cmd and -x $cmd ) {
        my $cmd_echo = qx( echo "quit;" | "$cmd" -z -quiet 2>&1 );
        return ( $cmd_echo =~ m{Firebird}ims ) ? 1 : 0;
    }
    return;
}

sub standard_fb_home_dirs {

    # Please, contribute other standard Firebird HOME paths here!
    return (
        qw{
          /opt/firebird
          /usr/local/firebird
          /usr/lib/firebird
          },
    );
}

sub locate_firebird_ms {

    my $hp_ref = registry_lookup('fb');
    if (ref $hp_ref) {
        my $fb_home_path = File::Spec->canonpath($hp_ref->[0]);
        my $isql_path = catfile($fb_home_path, 'bin', 'isql.exe');
        return $isql_path if check_if_is_fb_isql($isql_path);
    }

    return;
}

sub registry_lookup {
    my $what = shift;

    my $reg_data = read_data($what);

    my $value;
    foreach my $rec ( @{$reg_data->{$what}} ) {
        $value = read_registry($rec)
    }

    return $value;
}

sub read_registry {
    my $rec = shift;

    my (@path, $path);
    eval {
        require Win32::TieRegistry;

        $path =
          Win32::TieRegistry->new( $rec->{path} )->GetValue( $rec->{key} );
    };
    if ($@) {
        # TieRegistry fails on this key sometimes for some reason
        my $out = `reg query "$rec->{path}" /v $rec->{key}`;

        ($path) = $out =~ /REG_\w+\s+(.*)/;
    }

    $path =~ s/[\r\n]+//g;

    push @path, $path if $path;

    return wantarray ? @path : \@path;
}

sub read_data {
    my $app_alias = shift;

    my %reg_data;
    while (<DATA>) {
        my ($app, $key, $path) = split /:/, $_, 3;
        chomp $path;
        next if $app ne $app_alias;
        push @{ $reg_data{$app} }, { key => $key, path => $path } ;
    }

    return \%reg_data;
}

1;

#-- Known registry keys for the Firebird Project

__DATA__
fb:DefaultInstance:HKEY_LOCAL_MACHINE\SOFTWARE\Firebird Project\Firebird Server\Instances
