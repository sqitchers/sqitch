#!/usr/bin/perl -w

# local *main::^O;
BEGIN {
    $^O = 'MSWin32';
}

use strict;
use warnings;
use Test::More tests => 2;
use Try::Tiny;
use App::Sqitch::ItemFormatter;

is $^O, 'MSWin32', 'Should have "MSWin32"';
is App::Sqitch::ItemFormatter::CAN_OUTPUT_COLOR,
    try { require Win32::Console::ANSI },
    'CAN_OUTPUT_COLOR should be set properly';
