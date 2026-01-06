package App::Sqitch::Command::target;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use Types::Standard qw(Str Int HashRef);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use URI::db;
use Try::Tiny;
use Path::Class qw(file dir);
use List::Util qw(max);
use namespace::autoclean;
use constant extra_target_keys => qw(uri);

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::TargetConfigCommand';

# VERSION

sub configure {
    # No config; target config is actually targets.
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
    my %targets = $sqitch->config->get_regexp(key => qr/^target[.][^.]+[.]uri$/);

    # Make it verbose if --verbose was passed at all.
    my $format = $sqitch->options->{verbosity} ? "%1\$s\t%2\$s" : '%1$s';
    for my $key (sort keys %targets) {
        my ($target) = $key =~ /target[.]([^.]+)/;
        $sqitch->emit(sprintf $format, $target, $targets{$key});
    }

    return $self;
}

sub add {
    my ($self, $name, $uri) = @_;
    $self->usage unless $name && $uri;

    my $key    = "target.$name";
    my $config = $self->sqitch->config;

    hurl target => __x(
        'Target "{target}" already exists',
        target => $name
    ) if $config->get( key => "$key.uri");

    # Put together the URI and other config variables.
    my $vars = $self->config_params($key);
    unshift @{ $vars } => {
        key   => "$key.uri",
        value => URI::db->new($uri, 'db:')->as_string,
    };

    # Make it so.
    $config->group_set( $config->local_file, $vars );
    my $target = $self->config_target(name => $name);
    $self->write_plan(target => $target);
    $self->make_directories_for( $target );
    return $self;
}

sub alter {
    my ($self, $target) = @_;
    $self->usage unless $target;

    my $key    = "target.$target";
    my $config = $self->sqitch->config;
    my $props  = $self->properties;

    hurl target => __x(
        'Missing Target "{target}"; use "{command}" to add it',
        target  => $target,
        command => "add $target " . ($props->{uri} || '$uri'),
    ) unless $config->get( key => "target.$target.uri");

    # Make it so.
    $config->group_set( $config->local_file, $self->config_params($key) );
    $self->make_directories_for( $self->config_target(name => $target) );
}

sub rm { shift->remove(@_) }
sub remove {
    my ($self, $name) = @_;
    $self->usage unless $name;
    if ( my @deps = $self->_dependencies($name) ) {
        hurl target => __x(
            q{Cannot rename target "{target}" because it's referenced by: {engines}},
            target => $name,
            engines => join ', ', @deps
        );
    }
    $self->_rename($name);
}

sub rename {
    my ($self, $old, $new) = @_;
    $self->usage unless $old && $new;
    if ( my @deps = $self->_dependencies($old) ) {
        hurl target => __x(
            q{Cannot rename target "{target}" because it's referenced by: {engines}},
            target => $old,
            engines => join ', ', @deps
        );
    }
    $self->_rename($old, $new);
}

sub _dependencies {
    my ($self, $name) = @_;
    my %depends = $self->sqitch->config->get_regexp(
        key => qr/^(?:core|engine[.][^.]+)[.]target$/
    );
    return grep { $depends{$_} eq $name } sort keys %depends;
}

sub _rename {
    my ($self, $old, $new) = @_;
    my $config = $self->sqitch->config;

    try {
        $config->rename_section(
            from     => "target.$old",
            ($new ? (to => "target.$new") : ()),
            filename => $config->local_file,
        );
    } catch {
        die $_ unless /No such section/;
        hurl target => __x(
            'Unknown target "{target}"',
            target => $old,
        );
    };
    try {
        $config->rename_section(
            from     => "target.$old.variables",
            ($new ? (to => "target.$new.variables") : ()),
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

    my %label_for = (
        uri        => __('URI'),
        registry   => __('Registry'),
        client     => __('Client'),
        top_dir    => __('Top Directory'),
        plan_file  => __('Plan File'),
        extension  => __('Extension'),
        revert     => '  ' . __ 'Revert',
        deploy     => '  ' . __ 'Deploy',
        verify     => '  ' . __ 'Verify',
        reworked   => '  ' . __ 'Reworked',
    );

    my $len = max map { length } values %label_for;
    $_ .= ': ' . ' ' x ($len - length $_) for values %label_for;

    # Header labels.
    $label_for{script_dirs} = __('Script Directories') . ':';
    $label_for{reworked_dirs} = __('Reworked Script Directories') . ':';
    $label_for{variables} = __('Variables') . ':';
    $label_for{no_variables} = __('No Variables');

    require App::Sqitch::Target;
    for my $name (@names) {
        my $target = App::Sqitch::Target->new(
            $self->target_params,
            name   => $name,
        );
        $self->emit("* $name");
        $self->emit('    ', $label_for{uri},        $target->uri->as_string);
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

App::Sqitch::Command::target - Add, modify, or list Sqitch target databases

=head1 Synopsis

  my $cmd = App::Sqitch::Command::target->new(%params);
  $cmd->execute;

=head1 Description

Manages Sqitch targets, which are stored in the local configuration file.

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

  $target->execute($command);

Executes the C<target> command.

=head3 C<add>

Implements the C<add> action.

=head3 C<alter>

Implements the C<alter> action.

=head3 C<list>

Implements the C<list> action.

=head3 C<remove>

=head3 C<rm>

Implements the C<remove> action.

=head3 C<rename>

Implements the C<rename> action.

=head3 C<show>

Implements the C<show> action.

=head1 See Also

=over

=item L<sqitch-target>

Documentation for the C<target> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2026 David E. Wheeler, 2012-2021 iovation Inc.

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
