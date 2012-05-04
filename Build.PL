use strict;
use warnings;
use lib 'priv';
use Module::Build::Sqitch;

Module::Build::Sqitch->new(
    module_name        => 'App::Sqitch',
    release_status     => 'unstable',
    license            => 'mit',
    configure_requires => { 'Module::Build' => '0.35'  },
    requires           => {
        'perl'                                         => '5.10.1',
        'Carp'                                         => 0,
        'Config'                                       => 0,
        'Config::GitLike'                              => '1.07',
        'File::Basename'                               => 0,
        'File::Find::Rule'                             => '0.30',
        'File::HomeDir'                                => 0,
        'File::Path'                                   => 0,
        'File::Spec'                                   => 0,
        'Getopt::Long'                                 => 0,
        'Hash::Merge'                                  => 0,
        'IO::File'                                     => 0,
        'IPC::System::Simple'                          => '1.17',
        'List::Util'                                   => 0,
        'Moose'                                        => '1.15',
        'Moose::Util::TypeConstraints'                 => '1.15',
        'Moose::Meta::TypeConstraint::Parameterizable' => '1.15',
        'MooseX::Types::Path::Class'                   => '0.05',
        'namespace::autoclean'                         => '0.11',
        'Path::Class'                                  => 0,
        'Pod::Find'                                    => 0,
        'Pod::Usage'                                   => 0,
        'Template::Tiny'                               => '0.11',
        'Try::Tiny'                                    => 0,
    },
    build_requires => {
        'Capture::Tiny'        => '0.12',
        'Module::Build'        => '0.35',
        'Test::Dir'            => 0,
        'Test::File'           => 0,
        'Test::File::Contents' => '0.05',
        'Test::Exception'      => 0,
        'Test::MockModule'     => '0.05',
        'Test::More'           => '0.17',
        'Test::NoWarnings'     => '0.083',
        'File::HomeDir'        => 0,
        'File::Path'           => 0,
        'File::Spec'           => 0,
    },
    no_index => { directory => ['priv'] },
    recommends => {
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
