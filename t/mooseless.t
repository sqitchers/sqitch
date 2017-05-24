#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More;

use App::Sqitch;

ok ! exists($INC{'Moose.pm'}), 'no moose here';

done_testing();
