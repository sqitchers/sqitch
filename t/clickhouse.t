#!/usr/bin/perl -w

# To test against a live ClickHouse database, you must set the
# SQITCH_TEST_CLICKHOUSE_URI environment variable. this is a standard URI::db
# URI, and should look something like this:
#
#     export SQITCH_TEST_CLICKHOUSE_URI=db:clickhouse://default@localhost/default?Driver=ClickHouse
#

use strict;
use warnings;
use 5.010;
use Cwd qw(getcwd);
use Test::More;
use App::Sqitch;
use App::Sqitch::Target;
use Test::File::Contents;
use Test::MockModule;
use Path::Class;
use Try::Tiny;
use Test::Exception;
use Path::Class;
use List::MoreUtils qw(firstidx);
use Locale::TextDomain qw(App-Sqitch);
use File::Temp 'tempdir';
use DBD::Mem;
use lib 't/lib';
use DBIEngineTest;
use TestConfig;

my $CLASS;

BEGIN {
    $CLASS = 'App::Sqitch::Engine::clickhouse';
    require_ok $CLASS or die;
    delete $ENV{$_} for grep { /^CLICKHOUSE_/ } keys %ENV;
}

is_deeply [$CLASS->config_vars], [
    target   => 'any',
    registry => 'any',
    client   => 'any',
], 'config_vars should return three vars';

my $uri = URI::db->new('db:clickhouse:default');
my $config = TestConfig->new(
    'core.engine' => 'clickhouse',
    'engine.clickhouse.target' => $uri->as_string,
);
my $sqitch = App::Sqitch->new(config => $config);
my $target = App::Sqitch::Target->new(sqitch => $sqitch);
isa_ok my $ch = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;

is $ch->key, 'clickhouse', 'Key should be "clickhouse"';
is $ch->name, 'ClickHouse', 'Name should be "ClickHouse"';

my $client = 'clickhouse-client' . (App::Sqitch::ISWIN ? '.exe' : '');
is $ch->client, $client, 'client should default to clickhouse';
is $ch->registry, 'sqitch', 'registry default should be "sqitch"';
my $sqitch_uri = $uri->clone;
$sqitch_uri->dbname('sqitch');
is $ch->registry_uri, $sqitch_uri, 'registry_uri should be correct';
is $ch->uri, $uri, qq{uri should be "$uri"};
is $ch->_dsn, 'dbi:ODBC:DSN=sqitch', 'DSN should use DBD::ODBC with registry database';
is $ch->registry_destination, 'db:clickhouse:sqitch',
    'registry_destination should be the same as registry_uri';

my @std_opts = (
    '--progress'       => 'off',
    '--progress-table' => 'off',
    '--disable_suggestion',
);

my $mock_sqitch = Test::MockModule->new('App::Sqitch');
my $warning;
$mock_sqitch->mock(warn => sub { shift; $warning = [@_] });
$ch->uri->dbname('');
is_deeply [$ch->cli], [$client, @std_opts],
    'clickhouse command should be std opts-only';
is_deeply $warning, [__x
    'Database name missing in URI "{uri}"',
     uri => $ch->uri
], 'Should have emitted a warning for no database name';

isa_ok $ch = $CLASS->new(sqitch => $sqitch, target => $target), $CLASS;
ok $ch->set_variables(foo => 'baz', whu => 'hi there', yo => 'stellar'),
    'Set some variables';
is_deeply [$ch->cli], [
    $client,
    '--param_foo' => 'baz',
    '--param_whu' => 'hi there',
    '--param_yo' => 'stellar',
    @std_opts,
], 'Variables should be passed to psql via --set';

$mock_sqitch->unmock_all;

$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri => URI::db->new('db:clickhouse:'),
);
isa_ok $ch = $CLASS->new(
    sqitch => $sqitch,
    target => $target,
), $CLASS;

##############################################################################
# Make sure config and environment variables are read.
ENV: {
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(_clickcnf => {
        user     => 'lincoln',
        password => 's3cr3t',
        host     => 'bagel.cat',
        database => 'red',
    });

    my $uri = URI::db->new('db:clickhouse:');
    my $target = App::Sqitch::Target->new( sqitch => $sqitch, uri => $uri );
    ok my $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        'Create engine with env config set';
    is $ch->password, 's3cr3t', 'Password should be set from config';
    is $ch->username, 'lincoln', 'Username should be set from config';
    is $ch->uri, 'db:clickhouse://bagel.cat/red',
        'Host and database should be set from config';

    local $ENV{CLICKHOUSE_USER} = 'kamala';
    local $ENV{CLICKHOUSE_PASSWORD} = '__KAMALA';
    local $ENV{CLICKHOUSE_HOST} = 'sqitch.sql';
    $uri = URI::db->new('db:clickhouse:');
    $target = App::Sqitch::Target->new( sqitch => $sqitch, uri => $uri );
    ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        'Create engine with env vars set';
    is $ch->password, $ENV{CLICKHOUSE_PASSWORD},
        'Password should be set from environment';
    is $ch->username, $ENV{CLICKHOUSE_USER},
        'Username should be set from environment';
    is $ch->uri, 'db:clickhouse://sqitch.sql/red',
        'URI host should be set from environment';

    $uri = URI::db->new('db:clickhouse://bert:up@lol.host');
    $target = App::Sqitch::Target->new( sqitch => $sqitch, uri => $uri );
    ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        'Create engine with URI filled out';
    is $ch->password, 'up', 'Password should be set from URI';
    is $ch->username, 'bert', 'Username should be set from URI';
    is $ch->uri, 'db:clickhouse://bert:up@lol.host/red',
        'Host and database should be set from URI';
}

# Make sure uri reads the config.
URI_CONFIG: {
    my $mock = Test::MockModule->new($CLASS);
    my $cfg = {};
    $mock->mock(_clickcnf => $cfg);

    for my $tc (
        {
            test => 'empty',
            cfg  => {},
            uri => 'db:clickhouse:',
        },
        {
            test => 'basic',
            cfg  => {
                host     => 'bagel.cat',
                database => 'red',
            },
            uri => 'db:clickhouse://bagel.cat/red',
        },
        {
            test => 'secure',
            cfg  => {
                host     => 'bagel.cat',
                secure   => 1,
                database => 'red',
            },
            uri => 'db:clickhouse://bagel.cat/red?SSLMode=require',
        },
        {
            test => 'secure_no_repeat',
            cfg  => {
                host     => 'bagel.cat',
                secure   => 1,
                database => 'red',
            },
            target =>  => App::Sqitch::Target->new(
                sqitch => $sqitch,
                uri => URI::db->new('db:clickhouse:?SSLMode=require'),
            ),
            uri => 'db:clickhouse://bagel.cat/red?SSLMode=require',
        },
        {
            test => 'clickhouse.cloud',
            cfg  => {
                host     => 'xyz.clickhouse.cloud',
                database => 'red',
            },
            uri => 'db:clickhouse://xyz.clickhouse.cloud/red?SSLMode=require',
        },
        {
            test => 'secure port',
            cfg  => {
                host     => 'bagel.cat',
                port     => 9440,
                database => 'red',
            },
            uri => 'db:clickhouse://bagel.cat:8443/red?SSLMode=require',
        },
        {
            test => 'tls',
            cfg  => {
                host     => 'sushi.cat',
                database => 'green',
                tls      => {
                    privateKeyFile   => '/x/private.pem',
                    certificateFile  => '/x/cert.pem',
                    caConfig         => '/x/ca.pem',
                    verificationMode => 'strict',
                }
            },
            uri => 'db:clickhouse://sushi.cat/green',
            params => [
                [ PrivateKeyFile  => '/x/private.pem' ],
                [ CertificateFile => '/x/cert.pem'    ],
                [ CALocation      => '/x/ca.pem'      ],
                [ SSLMode         => 'require'        ],
            ]
        },
        {
            test => 'param mismatch',
            cfg  => {
                tls => { privateKeyFile => '/x/private.pem' }
            },
            target =>  => App::Sqitch::Target->new(
                sqitch => $sqitch,
                uri => URI::db->new('db:clickhouse:?PrivateKeyFile=/y/sinister.pem'),
            ),
            err => __x(
                'Client config {cfg_key} value "{cfg_val}" conflicts with ODBC param {odb_param} value "{odbc_val}"',
                cfg_key    => "openSSL.client.privateKeyFile",
                cfg_val    => '/x/private.pem',
                odbc_param => 'PrivateKeyFile',
                odbc_val   => '/y/sinister.pem',
            ),
        },
        {
            test => 'param match',
            cfg  => {
                tls => { privateKeyFile => '/x/private.pem' }
            },
            target =>  => App::Sqitch::Target->new(
                sqitch => $sqitch,
                uri => URI::db->new('db:clickhouse:?PrivateKeyFile=/x/private.pem'),
            ),
            uri => 'db:clickhouse:',
            params => [[ PrivateKeyFile => '/x/private.pem' ]],
        },
        {
            test => 'tls once',
            cfg  => {
                tls => { verificationMode => 'once' },
            },
            uri => 'db:clickhouse:?SSLMode=require',
        },
        {
            test => 'tls relaxed',
            cfg  => {
                tls => { verificationMode => 'relaxed' },
            },
            uri => 'db:clickhouse:?SSLMode=allow',
        },
        {
            test => 'tls none',
            cfg  => {
                tls => { verificationMode => 'none' },
            },
            uri => 'db:clickhouse:',
        },
        {
            test => 'no override secure',
            cfg  => {
                tls => { verificationMode => 'relaxed' },
            },
            uri => 'db:clickhouse:?SSLMode=allow',
        },
        {
            test => 'SSLMode overrides verificationMode',
            cfg  => {
                tls => { verificationMode => 'relaxed' },
            },
            target =>  => App::Sqitch::Target->new(
                sqitch => $sqitch,
                uri => URI::db->new('db:clickhouse:?SSLMode=require'),
            ),
            uri => 'db:clickhouse:?SSLMode=require',
        },
    ) {
        %{ $cfg } = %{ $tc->{cfg} };
        my $target = $tc->{target} || App::Sqitch::Target->new(
            sqitch => $sqitch, uri => URI::db->new('db:clickhouse:'),
        );
        $ch = $CLASS->new(sqitch => $sqitch, target => $target);
        my $uri = URI->new($tc->{uri});
        if (my $p = $tc->{params}) {
            $uri->query_param( @{ $_ }) for @{ $p };
        }
        if (my $err = $tc->{err}) {
            local $ENV{FOO} = 1;
            throws_ok { $ch->uri } 'App::Sqitch::X',
                "Should get error for $tc->{test} config";
            is $@->ident, 'engine', "Ident for $tc->{test} should be 'engine'";
            is $@->message, $tc->{err}, "Message for $tc->{test} should be correct";
        } else {
            is $ch->uri, $uri, "Should get URI for $tc->{test} config";
        }
    }
}

##############################################################################
# Make sure config settings override defaults and the password is set or removed
# as appropriate.
$config->update(
    'engine.clickhouse.client'   => '/path/to/clickhouse',
    'engine.clickhouse.target'   => 'db:clickhouse://me:pwd@foo.com/widgets',
    'engine.clickhouse.registry' => 'meta',
);
# my $ch_version = 'clickhouse  Ver 15.1 Distrib 10.0.15-MariaDB';
# $mock_sqitch->mock(probe => sub { $ch_version });
# push @std_opts => '--abort-source-on-error'
#     unless $std_opts[-1] eq '--abort-source-on-error';

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create another clickhouse';
is $ch->client, '/path/to/clickhouse', 'client should be as configured';
is $ch->uri->as_string, 'db:clickhouse://me:pwd@foo.com/widgets',
    'URI should be as configured';
like $ch->target->name, qr{^db:clickhouse://me:?\@foo\.com/widgets$},
    'target name should be the URI without the password';
like $ch->destination, qr{^db:clickhouse://me:?\@foo\.com/widgets$},
    'destination should be the URI without the password';
is $ch->registry, 'meta', 'registry should be as configured';
is $ch->registry_uri->as_string, 'db:clickhouse://me:pwd@foo.com/meta',
    'Sqitch DB URI should be the same as uri but with DB name "meta"';
like $ch->registry_destination, qr{^db:clickhouse://me:?\@foo\.com/meta$},
    'registry_destination should be the sqitch DB URL without the password';
is_deeply [$ch->cli], [
    '/path/to/clickhouse',
    'client',
    '--user',     'me',
    '--password', 'pwd',
    '--database', 'widgets',
    '--host',     'foo.com',
    @std_opts
], 'clickhouse command should be configured';

##############################################################################
# Make sure URI params get passed through to the client.
$target = App::Sqitch::Target->new(
    sqitch => $sqitch,
    uri    => URI->new('db:clickhouse://foo.com/widgets?SSLMode=require&NativePort=90210',
));
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with query params';
is_deeply [$ch->cli], [
    qw(/path/to/clickhouse client),
    qw(--database widgets --host foo.com),
    @std_opts,
    '--secure',
    '--port' => 90210,
], 'clickhouse command should be configured with query vals';

# Make sure the TLS HTTP ports trigger the encrypted native port.
for my $port (8443, 443) {
    my $target = App::Sqitch::Target->new(
        sqitch => $sqitch,
        uri    => URI->new("db:clickhouse://foo.com:$port/widgets",
    ));
    ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        "Create a clickhouse with URI port $port";
    is_deeply [$ch->cli], [
        qw(/path/to/clickhouse client),
        qw(--database widgets --host foo.com),
        @std_opts,
        '--port' => 9440,
    ], "clickhouse command should be configured with port 9449";
}

# But not when the configuration defines a port.
PORT: {
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(_clickcnf => { port => 8888 });
    my $target = App::Sqitch::Target->new(
        sqitch => $sqitch,
        uri    => URI->new("db:clickhouse://foo.com:443/widgets",
    ));
    ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
        "Create a clickhouse with default port 8888";
    is_deeply [$ch->cli], [
        qw(/path/to/clickhouse client),
        qw(--database widgets --host foo.com),
        @std_opts,
    ], "clickhouse command should not include --port";
}

##############################################################################
# Test _clickcnf
CONFIG: {
    my $orig_dir = getcwd();
    my $tmp_dir = tempdir CLEANUP => 1;
    chdir $tmp_dir;
    my $tmp_home = tempdir CLEANUP => 1;
    my $mock_config = Test::MockModule->new('App::Sqitch::Config');
    $mock_config->mock(home_dir => $tmp_home);

    # Write config files.
    for my $spec (
        [qw(temp . clickhouse-client)],
        ['home', $tmp_home, '.clickhouse-client'],
    ) {
        for my $ext (qw(xml yaml yml)) {
            my $path = file $spec->[1], "$spec->[2].$ext";
            open my $fh, '>:utf8', $path or die "Cannot open $path: $!";
            if ($ext eq 'xml') {
                print {$fh} qq{
                    <config>
                      <user>$spec->[0]</user>
                      <password>$ext</password>
                      <connections_credentials>
                        <connection>
                          <name>lol.cats</name>
                          <hostname>cats.example</hostname>
                        </connection>
                      </connections_credentials>
                    </config>
                };
            } else {
                print {$fh} qq{
                    user: $spec->[0]
                    password: $ext
                    connections_credentials:
                      connection:
                      - name: lol.cats
                        hostname: cats.example
                };
            }
        }
    }

    # Now find them in order.
    for my $spec (
        [qw(temp . clickhouse-client)],
        ['home', $tmp_home, '.clickhouse-client'],
    ) {
        for my $ext (qw(xml yaml yml)) {
            $target = App::Sqitch::Target->new(
                sqitch => $sqitch,
                uri    => URI->new('db:clickhouse://lol.cats',
            ));

            my $ch = $CLASS->new(sqitch => $sqitch, target => $target);
            ok my $cfg = $ch->_clickcnf, "Should load $ext config from $spec->[0]";
            is_deeply $cfg, {
                user     => $spec->[0],
                password => $ext,
                host     => 'cats.example',
            }, "Should have $ext config from $spec->[0]";
            unlink file $spec->[1], "$spec->[2].$ext";
        }
    }

    chdir $orig_dir;
}

##############################################################################
# Test _load_xml.
XML: {
    my $dir = dir qw(t click-conf);
    while (my $file = $dir->next) {
        next if $file !~ /\.xml$/;
        my $perl =  do{ (my $x = $file) =~ s/\.xml$/.pl/; file $x };
        my $exp = eval $perl->slurp;
        die "Failed to eval $perl: $@" if $@;
        my $got = App::Sqitch::Engine::clickhouse::_load_xml($file);
        is_deeply ($got, $exp, "Should have properly parsed $file");
    }
}

##############################################################################
# Test _is_true.
for my $t (qw(true on yes On YES True TRUE 42 99 -42 99.6)) {
    is App::Sqitch::Engine::clickhouse::_is_true $t, 1, "$t should be true";
}

for my $f ('', qw(0 0.0 false off no False FALSE Off nO)) {
    is App::Sqitch::Engine::clickhouse::_is_true $f, 0, "$f should be false";
}

##############################################################################
# Test _conn_cfg.
for my $tc (
    {
        test   => 'empty',
        config => {},
        exp    => {},
    },
    {
        test   => 'root only',
        config => {
            secure   => 'true',
            host     => 'bagel.cat',
            port     => 8000,
            user     => 'sushi',
            password => 's3cr3t',
            database => 'pets',
        },
        exp => {
            secure   => 1,
            host     => 'bagel.cat',
            port     => 8000,
            user     => 'sushi',
            password => 's3cr3t',
            database => 'pets',
        },
    },
    {
        test   => 'client TLS',
        config => {
            secure  => 'yes',
            user    => 'biscuit',
            openSSL => {
                client => {
                    caConfig => '/etc/ssl/cert.pem',
                }
            }
        },
        exp => {
            secure  => 1,
            user    => 'biscuit',
            tls => { caConfig => '/etc/ssl/cert.pem' },
        },
    },
    {
        test   => 'no client TLS',
        config => {
            secure  => 'no',
            openSSL => {
                server => {
                    caConfig => '/etc/ssl/cert.pem',
                }
            }
        },
        exp => { secure => 0 },
    },
    {
        test   => 'default connection',
        config => {
            secure   => 'true',
            user     => 'sushi',
            password => 's3cr3t',
            database => 'pets',
            connections_credentials => { connection => {
                name     => 'localhost',
                secure   => 'false',
                hostname => 'cats.lol',
                port     => 8181,
                user     => 'biscuit',
                password => 'meow',
                database => 'cats',
            }}
        },
        exp => {
            secure   => 0,
            host     => 'cats.lol',
            port     => 8181,
            user     => 'biscuit',
            password => 'meow',
            database => 'cats',
        },
    },
    {
        test   => 'different host',
        config => {
            secure   => 'true',
            host     => 'bagel.cat',
            user     => 'sushi',
            password => 's3cr3t',
            database => 'pets',
            connections_credentials => { connection => {
                name     => 'localhost',
                secure   => 'false',
                hostname => 'cats.lol',
                user     => 'biscuit',
                password => 'meow',
                database => 'cats',
            }}
        },
        exp => {
            secure   => 1,
            host     => 'bagel.cat',
            user     => 'sushi',
            password => 's3cr3t',
            database => 'pets',
        },
    },
    {
        test   => 'multiple connections',
        config => {
            connections_credentials => { connection => [
                {
                    name     => 'localhost',
                    user     => 'biscuit',
                },
                {
                    name     => 'pumpkin',
                    user     => 'pumpkin',
                },
            ]},
        },
        exp => {
            user => 'biscuit',
        },
    },
    {
        test   => 'repeat connection',
        config => {
            host => 'cats.lol',
            connections_credentials => { connection => [
                {
                    name     => 'localhost',
                    user     => 'biscuit',
                },
                {
                    user     => 'jimmy',
                },
                {
                    name     => 'cats.lol',
                    user     => 'pumpkin',
                },
                {
                    name     => 'cats.lol',
                    user     => 'strawberry',
                },
            ]},
        },
        exp => {
            host => 'cats.lol',
            user => 'strawberry',
        },
    },
    {
        test   => 'empty connections_credentials',
        config => {
            host => 'cats.lol',
            connections_credentials => {},
        },
        exp => {
            host => 'cats.lol',
        },
    },
) {
    my $got = App::Sqitch::Engine::clickhouse::_conn_cfg(
        $tc->{config}, $tc->{host},
    );
    is_deeply $got, $tc->{exp}, "Should process $tc->{test} config";
}

##############################################################################
# Test _run(), _capture(), and _spool().
can_ok $ch, qw(_run _capture _spool);
my $pass_env_name = 'CLICKHOUSE_PASSWORD';
my (@run, $exp_pass);
$mock_sqitch->mock(run => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @run = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

my @capture;
$mock_sqitch->mock(capture => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @capture = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

my @spool;
$mock_sqitch->mock(spool => sub {
    local $Test::Builder::Level = $Test::Builder::Level + 2;
    shift;
    @spool = @_;
    if (defined $exp_pass) {
        is $ENV{$pass_env_name}, $exp_pass, qq{$pass_env_name should be "$exp_pass"};
    } else {
        ok !exists $ENV{$pass_env_name}, '$pass_env_name should not exist';
    }
});

$target = App::Sqitch::Target->new(sqitch => $sqitch);
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with sqitch with options';
$exp_pass = 's3cr3t';
$target->uri->password($exp_pass);
ok $ch->_run(qw(foo bar baz)), 'Call _run';
is_deeply \@run, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to run()';

ok $ch->_spool('FH'), 'Call _spool';
is_deeply \@spool, [['FH'], $ch->cli],
    'Command should be passed to spool()';

ok $ch->_capture(qw(foo bar baz)), 'Call _capture';
is_deeply \@capture, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to capture()';

# Without password.
$target = App::Sqitch::Target->new( sqitch => $sqitch );
ok $ch = $CLASS->new(sqitch => $sqitch, target => $target),
    'Create a clickhouse with sqitch with no pw';
$exp_pass = undef;
$target->uri->password($exp_pass);
ok $ch->_run(qw(foo bar baz)), 'Call _run again';
is_deeply \@run, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to run() again';

ok $ch->_spool('FH'), 'Call _spool again';
is_deeply \@spool, [['FH'], $ch->cli],
    'Command should be passed to spool() again';

ok $ch->_capture(qw(foo bar baz)), 'Call _capture again';
is_deeply \@capture, [$ch->cli, qw(foo bar baz)],
    'Command should be passed to capture() again';

##############################################################################
# Test file and handle running.
ok $ch->run_file('foo/bar.sql'), 'Run foo/bar.sql';
is_deeply \@run, [$ch->cli, '--queries-file', 'foo/bar.sql'],
    'File should be passed to run()';
@run = ();

ok $ch->run_handle('FH'), 'Spool a "file handle"';
is_deeply \@spool, [['FH'], $ch->cli],
    'Handle should be passed to spool()';
@spool = ();

# Verify should go to capture unless verbosity is > 1.
ok $ch->run_verify('foo/bar.sql'), 'Verify foo/bar.sql';
is_deeply \@capture, [$ch->cli, '--queries-file', 'foo/bar.sql'],
    'Verify file should be passed to capture()';
@capture = ();

$mock_sqitch->mock(verbosity => 2);
ok $ch->run_verify('foo/bar.sql'), 'Verify foo/bar.sql again';
is_deeply \@run, [$ch->cli, '--queries-file', 'foo/bar.sql'],
    'Verify file should be passed to run() for high verbosity';
@run = ();

$ch->clear_variables;
$mock_sqitch->unmock_all;

##############################################################################
# Test DateTime formatting stuff.
can_ok $CLASS, '_ts2char_format';
is sprintf($CLASS->_ts2char_format, 'foo'),
    q{formatDateTime(foo, 'year:%Y:month:%m:day:%d:hour:%H:minute:%i:second:%S:time_zone:UTC')},
    '_ts2char_format should work';

ok my $dtfunc = $CLASS->can('_dt'), "$CLASS->can('_dt')";
isa_ok my $dt = $dtfunc->(
    'year:2012:month:07:day:05:hour:15:minute:07:second:01:time_zone:UTC'
), 'App::Sqitch::DateTime', 'Return value of _dt()';
is $dt->year, 2012, 'DateTime year should be set';
is $dt->month,   7, 'DateTime month should be set';
is $dt->day,     5, 'DateTime day should be set';
is $dt->hour,   15, 'DateTime hour should be set';
is $dt->minute,  7, 'DateTime minute should be set';
is $dt->second,  1, 'DateTime second should be set';
is $dt->time_zone->name, 'UTC', 'DateTime TZ should be set';

##############################################################################
# Test SQL helpers.
is $ch->_listagg_format, q{groupArraySorted(10000)(%1$s)},
    'Should have _listagg_format';
is $ch->_regex_op, 'REGEXP', 'Should have _regex_op';
is $ch->_simple_from, '', 'Should have _simple_from';
is $ch->_limit_default, undef, 'Should have no _limit_default';

is $ch->_ts_default, q{now64(6, 'UTC')},
    'Should have _ts_default with now64()';

DBI: {
    local *DBI::state;
    ok !$ch->_no_table_error, 'Should have no table error';
    ok !$ch->_no_column_error, 'Should have no column error';
    dies_ok { $ch->_initialized } '_initialized should die';
    dies_ok { $ch->_cid('ASC') } '_cid should die';
    $DBI::state = 'HY000';
    ok $ch->_no_table_error, 'Should now have table error';
    ok !$ch->_no_column_error, 'Still should have no column error';
    ok !$ch->_initialized, 'Should get false from _initialized';
    is undef, $ch->_cid('ASC'), 'Should get undef from _cid';
    $DBI::state = '42703';
    ok !$ch->_no_table_error, 'Should again have no table error';
    ok $ch->_no_column_error, 'Should now have no column error';
    ok !$ch->_unique_error, 'Unique constraints not supported by ClickHouse';
}

is_deeply [$ch->_limit_offset(8, 4)],
    [['LIMIT 8', 'OFFSET 4'], []],
    'Should get limit and offset';
is_deeply [$ch->_limit_offset(0, 2)],
    [['OFFSET 2'], []],
    'Should get limit and offset when offset only';
is_deeply [$ch->_limit_offset(12, 0)], [['LIMIT 12'], []],
    'Should get only limit with 0 offset';
is_deeply [$ch->_limit_offset(12)], [['LIMIT 12'], []],
    'Should get only limit with noa offset';
is_deeply [$ch->_limit_offset(0, 0)], [[], []],
    'Should get no limit or offset for 0s';
is_deeply [$ch->_limit_offset()], [[], []],
    'Should get no limit or offset for no args';

is_deeply [$ch->_regex_expr('corn', 'Obama$')],
    ['corn REGEXP ?', 'Obama$'],
    'Should use REGEXP for regex expr';

##############################################################################
# Test parse_array.
is_deeply $ch->_parse_array(''), [], 'Should get empty array from empty string';
is_deeply $ch->_parse_array(undef), [], 'Should get empty array from undef';
is_deeply $ch->_parse_array('no'), [], 'Should get empty array invalid array';
is_deeply $ch->_parse_array('[1]'), [1], 'Should parse single int array';
is_deeply $ch->_parse_array('[1, 2, 3]'), [1,2,3], 'Should parse int array';
is_deeply $ch->_parse_array(q{['hi']}), ['hi'], 'Should parse single string array';
is_deeply $ch->_parse_array(q{['O\'Toole']}), ["O'Toole"],
    'Should parse string array with escape';
is_deeply $ch->_parse_array(q{['bread\\water']}), ['bread\\water'],
    'Should parse string array with escape slash';
is_deeply $ch->_parse_array(q{['🏠']}), ['🏠'],
    'Should parse string array with Unicode';
is_deeply $ch->_parse_array(q{['', 'hi', 'there']}), ['hi', 'there'],
    'Should pop empty string when first value in array';
is_deeply $ch->_parse_array(q{['']}), [],
    'Should pop empty string when only value in array';

# Test _version_query
is $ch->_version_query,
    'SELECT CAST(ROUND(MAX(version), 1) AS CHAR) FROM releases',
    'Should have version query';

##############################################################################
# Test unexpected database error in initialized() and _cid().
MOCKDBH: {
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(dbh => sub { die 'OW' });
    throws_ok { $ch->initialized } qr/OW/,
        'initialized() should rethrow unexpected DB error';
    throws_ok { $ch->_cid } qr/OW/,
        '_cid should rethrow unexpected DB error';
}

##############################################################################
# Test run_upgrade().
UPGRADE: {
    # Mock run.
    my @run;
    $mock_sqitch->mock(run => sub { shift; @run = @_ });

    # Mock File::Temp so we hang on to the file.
    my $mock_ft = Test::MockModule->new('File::Temp');
    my $tmp_fh;
    my $ft_new;
    $mock_ft->mock(new => sub { $tmp_fh = 'File::Temp'->$ft_new() });
    $ft_new = $mock_ft->original('new');

    # Assemble the expected command.
    my @cmd = $ch->cli;
    my $db_opt_idx = firstidx { $_ eq '--database' } @cmd;
    $cmd[$db_opt_idx + 1] = $ch->registry;
    my $fn = file($INC{'App/Sqitch/Engine/clickhouse.pm'})->dir->file('clickhouse.sql');

    # Test the upgrade.
    ok $ch->run_upgrade($fn), 'Run the upgrade';
    is $tmp_fh, undef, 'Should not have created a temp file';
    is_deeply \@run, [@cmd, '--queries-file', $fn],
        'It should have run the unchanged file';

    # Test without the --database option.
    splice @cmd, $db_opt_idx, 2;
    my $mock = Test::MockModule->new($CLASS);
    $mock->mock(cli => sub { @cmd });
    ok $ch->run_upgrade($fn), 'Run the upgrade';
    is $tmp_fh, undef, 'Should not have created a temp file';
    is_deeply \@run, [@cmd, '--database', $ch->registry, '--queries-file', $fn],
        'It should appended the --database option';

    $mock_sqitch->unmock_all;
}

##############################################################################
# Make sure log_new_tags returns if no tags.
ok $ch->log_new_tags(App::Sqitch::Plan::Change->new(
    name => 'hi',
    plan => App::Sqitch::Plan->new(sqitch => $sqitch, target => $target),
)), 'log_new_tags should just return when no tags to log';

# Make sure we have templates.
DBIEngineTest->test_templates_for($ch->key);

##############################################################################
# Can we do live tests?
my $dbh;
my $id = DBIEngineTest->randstr;
my ($db, $reg1, $reg2) = map { $_ . $id } qw(__sqitchtest__ __metasqitch __sqitchtest);

END {
    return unless $dbh;
    $dbh->{Driver}->visit_child_handles(sub {
        my $h = shift;
        $h->disconnect if $h->{Type} eq 'db' && $h->{Active} && $h ne $dbh;
    });

    return unless $dbh->{Active};
    $dbh->do("DROP DATABASE IF EXISTS $_") for ($db, $reg1, $reg2);
    $dbh->disconnect;
}

$uri = URI->new(
    $ENV{SQITCH_TEST_CLICKHOUSE_URI} ||
    'db:clickhouse://default@localhost/default?Driver=ClickHouse'
);
$uri->dbname('default') unless $uri->dbname;

my $err = try {
    $ch->use_driver;
    $dbh = DBI->connect($uri->dbi_dsn, $uri->user, $uri->password, {
        PrintError  => 0,
        RaiseError  => 0,
        AutoCommit  => 1,
        HandleError => $ch->error_handler,
    });

    $dbh->do("CREATE DATABASE $db");
    $uri->dbname($db);
    undef;
} catch {
    $_
};

DBIEngineTest->run(
    class             => $CLASS,
    no_unique         => 1,
    target_params     => [ registry => $reg1, uri => $uri ],
    alt_target_params => [ registry => $reg2, uri => $uri ],
    skip_unless       => sub {
        my $self = shift;
        die $err if $err;
        # Make sure we have the clickhouse CLI & can connect to the database.
        my $version = $self->sqitch->capture( $self->client, '--version' );
        say "# Detected CLI $version";
        say '# Connected to ClickHouse ' . $self->_capture('--query' => 'SELECT version()');
        1;
    },
    engine_err_regex  => qr/^Error while processing query /,
    init_error        => __x(
        'Sqitch database {database} already initialized',
        database => $reg2,
    ),
    test_dbh => sub {
        my $dbh = shift;
        # Make sure the sqitch schema is the current database.
        is $dbh->selectcol_arrayref('SELECT current_database()')->[0],
            $reg2, 'The Sqitch database should be the current database';
    },
);

done_testing;
