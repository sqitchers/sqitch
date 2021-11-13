#!/usr/bin/perl -w

use strict;
use Test::More;
use Test::Pod::Coverage 1.08;

Test::Pod::Coverage::all_pod_coverage_ok({
    also_private   => [qw(BUILDARGS BUILD CAN_OUTPUT_COLOR OUTPUT_TO_PIPE)],
    coverage_class => 'Pod::Coverage::CountParents',
});
