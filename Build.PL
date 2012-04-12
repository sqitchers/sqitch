use strict;
use warnings;
use Module::Build;

Module::Build->new(
    module_name        => 'App::Sqitch',
    license            => 'mit',
    requires           => { perl            => '5.10.1' },
    configure_requires => { 'Module::Build' => '0.35'  },
    build_requires     => {
        'Module::Build'        => '0.35',
        'Test::More'           => '0.17',
    },
    requires => {
        'Class::Accessor::Fast' => '0.31',
        'Getopt::Long'          => 0,
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
