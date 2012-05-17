#!/usr/bin/perl -w

use strict;
use Test::More;
eval "use Test::Pod::Coverage 1.08";
plan skip_all => "Test::Pod::Coverage 1.08 required for testing POD coverage"
  if $@;

all_pod_coverage_ok({
    also_private   => ['BUILDARGS'],
    coverage_class => 'Pod::Coverage::CountParents',
});
