package App::Sqitch::Command::engine;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use Types::Standard qw(Str Int HashRef);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Try::Tiny;
use URI::db;
use Path::Class qw(file dir);
use List::Util qw(max first);
use namespace::autoclean;
use constant extra_target_keys => qw(target);

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::TargetConfigCommand';

our $VERSION = '0.9994';

has verbose => (
    is      => 'ro',
    isa     => Int,
    default => 0,
);

sub options { qw(verbose|v+) }

sub _chk_engine($) {
    my $engine = shift;
    hurl engine => __x(
        'Unknown engine "{engine}"', engine => $engine
    ) unless first { $engine eq $_ } App::Sqitch::Command::ENGINES;
}

sub configure {
    my ( $class, $config, $options ) = @_;
    # No config; engine config is actually engines.
    return { verbose => $options->{verbose} } if exists $options->{verbose};
    return {};
}

sub execute {
    my ( $self, $action ) = (shift, shift);
    $action ||= 'list';
    $action =~ s/-/_/g;
    my $meth = $self->can($action) or $self->usage(__x(
        'Unknown action "{action}"',
        action => $action,
    ));

    return $self->$meth(@_);
}

sub list {
    my $self    = shift;
    my $sqitch  = $self->sqitch;
    my $rx = join '|' => App::Sqitch::Command::ENGINES;
    my %engines = $sqitch->config->get_regexp(key => qr/^engine[.](?:$rx)[.]target$/);

    my $format = $self->verbose ? "%1\$s\t%2\$s" : '%1$s';
    for my $key (sort keys %engines) {
        my ($engine) = $key =~ /engine[.]([^.]+)/;
        $sqitch->emit(sprintf $format, $engine, $engines{$key})
    }

    return $self;
}

sub _target {
    my ($self, $engine, $name) = @_;
    my $target = $self->properties->{target} || $name || return;
    my $config = $self->sqitch->config;

    if ($target =~ /:/) {
        # It's  URI. Return it if it uses the proper engine.
        my $uri = URI::db->new($target, 'db:');
        hurl engine => __x(
            'Cannot assign URI using engine "{new}" to engine "{old}"',
            new => $uri->canonical_engine,
            old => $engine,
        ) if $uri->canonical_engine ne $engine;
        return $uri->as_string;
    }

    # Otherwise, it needs to be a known target from the config.
    return $target if $config->get(key => "target.$target.uri");
    hurl engine => __x(
        'Unknown target "{target}"',
        target => $target
    );
}

sub add {
    my ($self, $engine, $target) = @_;
    $self->usage unless $engine;
    _chk_engine $engine;

    my $key    = "engine.$engine";
    my $config = $self->sqitch->config;

    hurl engine => __x(
        'Engine "{engine}" already exists',
        engine => $engine
    ) if $config->get( key => "$key.target");

    # Set up the target.
    my @vars = ({
        key   => "$key.target",
        value => $self->_target($engine, $target) || "db:$engine:",
    });

    # Add the other properties.
    my $props = $self->properties;
    while (my ($prop, $val) = each %{ $props } ) {
        push @vars => {
            key   => "$key.$prop",
            value => $val,
        } if $prop ne 'target';
    }

    # Make it so.
    $config->group_set( $config->local_file, \@vars );
    $target = $self->config_target(
        name   => $target,
        engine => $engine,
    );
    $self->write_plan(target => $target);
    $self->make_directories_for($target);
}

sub alter {
    my ($self, $engine) = @_;
    $self->usage unless $engine;
    _chk_engine $engine;

    my $key    = "engine.$engine";
    my $config = $self->sqitch->config;
    my $props  = $self->properties;

    hurl engine => __x(
        'Missing Engine "{engine}"; use "{command}" to add it',
        engine  => $engine,
        command => "add $engine " . ($props->{target} || "db:$engine:"),
    ) unless $config->get( key => "engine.$engine.target");

    my @vars;
    while (my ($prop, $val) = each %{ $props } ) {
        if ($prop eq 'target') {
            $val = $self->_target($engine, $val) or hurl engine => __(
                'Cannot unset an engine target'
            );
        }
        push @vars => {
            key   => "$key.$prop",
            value => $val,
        };
    }

    # Make it so.
    $config->group_set( $config->local_file, \@vars );
    $self->make_directories_for( $self->config_target( engine => $engine) );
}

# XXX Begin deprecated.

sub _set {
    my ($self, $key, $engine, $value) = @_;
    (my $action = $key) =~ s/_/-/g;
    $self->usage unless $engine && $value;
    (my $opt = $key) =~ s/_/-/g;
    $self->sqitch->warn(__x(
        qq{  The "{old}" action is deprecated;\n  Instead use "{new}".},
        old => "set-$action $engine $value",
        new => "alter $engine --$opt $value",
    ));

    _chk_engine $engine;

    my $config = $self->sqitch->config;

    hurl engine => __x(
        'Unknown engine "{engine}"',
        engine => $engine
    ) unless $config->get( key => "engine.$engine.target");

    $config->set(
        key      => "engine.$engine.$key",
        value    => $value,
        filename => $config->local_file,
    );
    return $self;
}

my %normalizer_for = (
    top_dir   => sub { $_[0] ? dir($_[0])->cleanup : undef },
    plan_file => sub { $_[0] ? file($_[0])->cleanup : undef },
    client    => sub { $_[0] },
    target    => sub {
        my $target = shift or return undef;
        # Return a normalized URI if it looks like a URI.
        return URI::db->new($target, 'db:')->as_string if $target =~ /:/;
        # Otherwise, it needs to be a known target from the config.
        my $config = shift;
        return $target if $config->get(key => "target.$target.uri");
        hurl engine => __x(
            'Unknown target "{target}"',
            target => $target
        );
    },
);

$normalizer_for{"$_\_dir"} = $normalizer_for{"reworked_$_\_dir"} = $normalizer_for{top_dir}
    for qw(deploy revert verify);
$normalizer_for{reworked_dir} = $normalizer_for{top_dir};
$normalizer_for{$_} = $normalizer_for{client} for qw(registry extension);

sub set_target {
    my ($self, $engine, $target) = @_;
    $self->_set( 'target', $engine, $normalizer_for{target}->(
        $target, $self->sqitch->config,
    ) );
}

sub set_registry  { shift->_set('registry',  @_) }
sub set_client    { shift->_set('client',    @_) }
sub set_extension { shift->_set('extension', @_) }

sub _set_dir {
    my ($self, $key, $engine, $dir) = @_;
    $self->_set( $key, $engine, $normalizer_for{top_dir}->($dir) );
}

sub set_top_dir    { shift->_set_dir('top_dir',    @_) }
sub set_deploy_dir { shift->_set_dir('deploy_dir', @_) }
sub set_revert_dir { shift->_set_dir('revert_dir', @_) }
sub set_verify_dir { shift->_set_dir('verify_dir', @_) }

sub set_plan_file {
    my ($self, $engine, $file) = @_;
    $self->_set( 'plan_file', $engine, $normalizer_for{plan_file}->($file) );
}

# XXX End deprecated.

sub rm { shift->remove(@_) }
sub remove {
    my ($self, $engine) = @_;
    $self->usage unless $engine;

    my $config = $self->sqitch->config;
    try {
        $config->rename_section(
            from     => "engine.$engine",
            filename => $config->local_file,
        );
    } catch {
        die $_ unless /No such section/;
        hurl engine => __x(
            'Unknown engine "{engine}"',
            engine => $engine,
        );
    };
    return $self;
}

sub show {
    my ($self, @names) = @_;
    return $self->list unless @names;
    my $sqitch = $self->sqitch;
    my $config = $sqitch->config;

    # Set up labels.
    my %label_for = (
        target       => __ 'Target',
        registry     => __ 'Registry',
        client       => __ 'Client',
        top_dir      => __ 'Top Directory',
        plan_file    => __ 'Plan File',
        extension    => __ 'Extension',
        revert       => '  ' . __ 'Revert',
        deploy       => '  ' . __ 'Deploy',
        verify       => '  ' . __ 'Verify',
        reworked     => '  ' . __ 'Reworked',
    );

    my $len = max map { length } values %label_for;
    $_ .= ': ' . ' ' x ($len - length $_) for values %label_for;

    # Header labels.
    $label_for{script_dirs} = __('Script Directories') . ':';
    $label_for{reworked_dirs} = __('Reworked Script Directories') . ':';

    require App::Sqitch::Target;
    for my $engine (@names) {
        my $target = App::Sqitch::Target->new(
            sqitch => $sqitch,
            name   => $config->get(key => "engine.$engine.target") || "db:$engine",
        );

        $self->emit("* $engine");
        $self->emit('    ', $label_for{target},     $target->target);
        $self->emit('    ', $label_for{registry},   $target->registry);
        $self->emit('    ', $label_for{client},     $target->client);
        $self->emit('    ', $label_for{top_dir},    $target->top_dir);
        $self->emit('    ', $label_for{plan_file},  $target->plan_file);
        $self->emit('    ', $label_for{extension},  $target->extension);
        $self->emit('    ', $label_for{script_dirs});
        $self->emit('    ', $label_for{deploy}, $target->deploy_dir);
        $self->emit('    ', $label_for{revert}, $target->revert_dir);
        $self->emit('    ', $label_for{verify}, $target->verify_dir);
        $self->emit('    ', $label_for{reworked_dirs});
        $self->emit('    ', $label_for{reworked}, $target->reworked_dir);
        $self->emit('    ', $label_for{deploy}, $target->reworked_deploy_dir);
        $self->emit('    ', $label_for{revert}, $target->reworked_revert_dir);
        $self->emit('    ', $label_for{verify}, $target->reworked_verify_dir);
    }

    return $self;
}

sub update_config {
    my $self = shift;
    my $sqitch = $self->sqitch;
    my $config = $sqitch->config;

    my $local_file = $config->local_file;
    for my $file (
        $local_file,
        $config->user_file,
        $config->system_file,
    ) {
        $sqitch->emit(__x( 'Loading {file}', file => $file ));
        # Hide all other files. Just want to deal with the one.
        local $ENV{SQITCH_CONFIG}        = '/dev/null/not.conf';
        local $ENV{SQITCH_USER_CONFIG}   = '/dev/null/not.user';
        local $ENV{SQITCH_SYSTEM_CONFIG} = '/dev/null/not.sys';
        my $c = App::Sqitch::Config->new;
        $c->load_file($file);
        my %engines;
        for my $ekey (App::Sqitch::Command::ENGINES) {
            my $sect = $c->get_section( section => "core.$ekey");
            if (%{ $sect }) {
                if (%{ $c->get_section( section => "engine.$ekey") }) {
                    $sqitch->warn('  - ' . __x(
                        "Deprecated {section} found in {file}; to remove it, run\n    {sqitch} config --file {file} --remove-section {section}",
                        section => "core.$ekey",
                        file    => $file,
                        sqitch  => $0,
                    ));
                    next;
                }
                # Migrate this one.
                $engines{$ekey} = $sect;
            }
        }
        unless (%engines) {
            $sqitch->emit(__ '  - No engines to update');
            next;
        }

        # Make sure we can write to the file.
        unless (-w $file) {
            $sqitch->warn('  - ' . __x(
                'Cannot update {file}. Please make it writable',
                file => $file,
            ));
            next;
        }

        # Move all of the engines.
        for my $ekey (sort keys %engines) {
            my $old = $engines{$ekey};

            my @new;
            if ( my $target = delete $old->{target} ) {
                # Good, there is already a specific target.
                push @new => {
                    key => "engine.$ekey.target",
                    value => $target,
                };
                # Kill off deprecated variables.
                delete $old->{$_} for qw(host port username password db_name);
            } elsif ( $file eq $local_file ) {
                # Start with a default and migrate deprecated configs.
                my $uri = URI::db->new("db:$ekey:");
                for my $spec (
                    [host     => 'host'],
                    [port     => 'port'],
                    [username => 'user'],
                    [password => 'password'],
                    [db_name  => 'dbname'],
                ) {
                    my ($key, $meth) = @{ $spec };
                    my $val = delete $old->{$key} or next;
                    $uri->$meth($val);
                }
                push @new => {
                    key => "engine.$ekey.target",
                    value => $uri->as_string,
                };
            } else {
                # Just kill off any of the deprecated variables.
                delete $old->{$_} for qw(host port username password db_name);
            }

            # Copy over the remaining variabls.
            push @new => map {{
                key => "engine.$ekey.$_",
                value => $old->{$_},
            }} keys %{ $old };

            # Create the new variables and delete the old section.
            $config->group_set( $file, \@new );
            # $c->rename_section(
            #     from     => "core.$ekey",
            #     filename => $file,
            # );

            $sqitch->emit('  - ' . __x(
                "Migrated {old} to {new}; To remove {old}, run\n    {sqitch} config --file {file} --remove-section {old}",
                old    => "core.$ekey",
                new    => "engine.$ekey",
                sqitch => $0,
                file   => $file,
            ));
        }
    }
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::engine - Add, modify, or list Sqitch database engines

=head1 Synopsis

  my $cmd = App::Sqitch::Command::engine->new(%params);
  $cmd->execute;

=head1 Description

Manages Sqitch database engines, which are stored in the local configuration file.

=head1 Interface

=head3 Class Methods

=head3 C<extra_target_keys>

Returns a list of additional option keys to be specified via options.

=head2 Instance Methods

=head2 Attributes

=head3 C<properties>

Hash of property values to set.

=head3 C<verbose>

Verbosity.

=head3 C<execute>

  $engine->execute($command);

Executes the C<engine> command.

=head3 C<add>

Implements the C<add> action.

=head3 C<alter>

Implements the C<alter> action.

=head3 C<list>

Implements the C<list> action.

=head3 C<remove>

=head3 C<rm>

Implements the C<remove> action.

=begin comment

Deprecated methods.

=head3 C<set_target>

Implements the C<set-target> action.

=head3 C<set_client>

Implements the C<set-client> action.

=head3 C<set_registry>

Implements the C<set-registry> action.

=head3 C<set_top_dir>

Implements the C<set-top-dir> action.

=head3 C<set_plan_file>

Implements the C<set-plan-file> action.

=head3 C<set_deploy_dir>

Implements the C<set-deploy-dir> action.

=head3 C<set_revert_dir>

Implements the C<set-revert-dir> action.

=head3 C<set_verify_dir>

Implements the C<set-verify-dir> action.

=head3 C<set_reworked_dir>

Implements the C<set-reworked-dir> action.

=head3 C<set_reworked_deploy_dir>

Implements the C<set-reworked-deploy-dir> action.

=head3 C<set_reworked_revert_dir>

Implements the C<set-reworked-revert-dir> action.

=head3 C<set_reworked_verify_dir>

Implements the C<set-reworked-verify-dir> action.

=head3 C<set_extension>

Implements the C<set-extension> action.

=end comment

=head3 C<show>

Implements the C<show> action.

=head3 C<update_config>

Implements the C<update_config> action.

=head1 See Also

=over

=item L<sqitch-engine>

Documentation for the C<engine> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2015 iovation Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut
