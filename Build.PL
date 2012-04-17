use strict;
use warnings;
use Module::Build;

Module::Build->new(
    module_name        => 'App::Sqitch',
    license            => 'mit',
    requires           => { perl            => '5.10.1' },
    configure_requires => { 'Module::Build' => '0.35'  },
    build_requires     => {
        'Capture::Tiny'        => 0,
        'Module::Build'        => '0.35',
        'Test::MockModule'     => '0.05',
        'Test::More'           => '0.17',
        'File::Spec'           => 0,
    },
    requires => {
        'Class::Accessor::Fast' => '0.31',
        'Config::INI::Reader'   => 0,
        'File::HomeDir'         => 0,
        'Getopt::Long'          => 0,
        'Path::Class'           => 0,
    },
    recommends         => {
        'Test::Pod'  => '1.41',
    },
    meta_merge => {
        resources => {
            homepage    => 'http://sqitch.org/',
            bugtracker  => 'http://github.com/theory/sqitch/issues/',
            repository  => 'http://github.com/theory/sqitch/',
        }
    },
)->create_build_script;
