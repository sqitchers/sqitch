#!/usr/bin/perl -w

use strict;
use warnings;
use utf8;
use Test::More;
use Module::Runtime qw(use_module);
use Test::Exception;

no Moo::sification;

lives_ok { use_module 'App::Sqitch';  };


done_testing();
