use strict;
use warnings;
use Module::Build;

Module::Build->new(
    module_name        => 'App::Sqitch',
    license            => 'mit',
    requires           => { perl            => '5.10.1' },
    configure_requires => { 'Module::Build' => '0.35'  },
    build_requires     => {
        'Capture::Tiny'        => '0.12',
        'Module::Build'        => '0.35',
        'Test::Exception'      => 0,
        'Test::MockModule'     => '0.05',
        'Test::More'           => '0.17',
        'Test::NoWarnings'     => '0.083',
        'File::HomeDir'        => 0,
        'File::Path'           => 0,
        'File::Spec'           => 0,
    },
    requires => {
        'Class::Accessor::Fast'        => '0.31',
        'Config::GitLike'              => '1.07',
        'File::HomeDir'                => 0,
        'Getopt::Long'                 => 0,
        'Hash::Merge'                  => 0,
        'Moose'                        => '1.15',
        'Moose::Util::TypeConstraints' => '1.15',
        'Path::Class'                  => 0,
        'Try::Tiny'                    => 0,
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
