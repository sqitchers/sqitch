#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;

use Test::More;
use File::Find qw(find);
use Module::Runtime qw(use_module);

my $test = sub {
    return unless $_ =~ /\.pm$/;

	my $module = $File::Find::name;
	$module =~ s!^(blib[/\\])?lib[/\\]!!;
	$module =~ s![/\\]!::!g;
	$module =~ s/\.pm$//;

    eval { use_module $module; };
    if ($@) {
        diag "Couldn't load $module: $@";
        undef $@;
        return;
    }

    ok ! $INC{'Moose.pm'}, "No moose in $module";
};

find($test, 'lib');

done_testing();
