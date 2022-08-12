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

# VERSION

sub _chk_engine($) {
    my $engine = shift;
    hurl engine => __x(
        'Unknown engine "{engine}"', engine => $engine
    ) unless first { $engine eq $_ } App::Sqitch::Command::ENGINES;
}

sub configure {
    # No config; engine config is actually engines.
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

    # Make it verbose if --verbose was passed at all.
    my $format = $sqitch->options->{verbosity} ? "%1\$s\t%2\$s" : '%1$s';
    for my $key (sort keys %engines) {
        my ($engine) = $key =~ /engine[.]([^.]+)/;
        $sqitch->emit(sprintf $format, $engine, $engines{$key})
    }

    return $self;
}

sub _target {
    my ($self, $engine, $name) = @_;
    my $target = $self->properties->{target} || $name || return;

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
    return $target if $self->sqitch->config->get(key => "target.$target.uri");
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

    # Set up the target and other config variables.
    my $vars = $self->config_params($key);
    unshift @{ $vars } => {
        key   => "$key.target",
        value => $self->_target($engine, $target) || "db:$engine:",
    };

    # Make it so.
    $config->group_set( $config->local_file, $vars );
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

    if (my $targ = $props->{target}) {
        $props->{target} = $self->_target($engine, $targ) or hurl engine => __(
            'Cannot unset an engine target'
        );
    }

    # Make it so.
    $config->group_set( $config->local_file, $self->config_params($key) );
    $self->make_directories_for( $self->config_target( engine => $engine) );
}

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
    try {
        $config->rename_section(
            from     => "engine.$engine.variables",
            filename => $config->local_file,
        );
    } catch {
        die $_ unless /No such section/;
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
    $label_for{variables} = __('Variables') . ':';
    $label_for{no_variables} = __('No Variables');

    require App::Sqitch::Target;
    for my $engine (@names) {
        my $target = App::Sqitch::Target->new(
            $self->target_params,
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
        my $vars = $target->variables;
        if (%{ $vars }) {
            my $len = max map { length } keys %{ $vars };
            $self->emit('    ', $label_for{variables});
            $self->emit("  $_: " . (' ' x ($len - length $_)) . $vars->{$_})
                for sort { lc $a cmp lc $b } keys %{ $vars };
        } else {
            $self->emit('    ', $label_for{no_variables});
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

=head3 C<show>

Implements the C<show> action.

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

Copyright (c) 2012-2022 iovation Inc., David E. Wheeler

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
