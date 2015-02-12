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

extends 'App::Sqitch::Command';

our $VERSION = '0.999_1';

has verbose => (
    is      => 'ro',
    isa     => Int,
    default => 0,
);

has properties => (
    is      => 'ro',
    isa     => HashRef,
    default => sub { {} },
);

sub options {
    return qw(
        set|s=s%
        registry|r=s
        client|c=s
        verbose|v+
    );
}

my %normalizer_for = (
    top_dir   => sub { $_[0] ? dir($_[0])->cleanup : undef },
    plan_file => sub { $_[0] ? file($_[0])->cleanup : undef },
    client    => sub { $_[0] },
);

$normalizer_for{"$_\_dir"} = $normalizer_for{top_dir} for qw(deploy revert verify);
$normalizer_for{$_} = $normalizer_for{client} for qw(registry extension);

sub configure {
    my ( $class, $config, $options ) = @_;

    # Handle deprecated options.
    for my $key (qw(registry client)) {
        my $val = delete $options->{$key} or next;
        App::Sqitch->warn(__x(
            'Option --{key} has been deprecated; use "--set {key}={val}" instead',
            key => $key,
            val => $val
        ));
        my $set = $options->{set} ||= {};
        $set->{$key} = $val;
    }

    $options->{properties} = delete $options->{set}
        if $options->{set};

    # No config; target config is actually targets.
    return $options;
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

    my $format = $self->verbose ? "%1\$s\t%2\$s" : '%1$s';
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

    my @vars = ({
        key   => "$key.uri",
        value => URI::db->new($uri, 'db:')->as_string,
    });

    # Collect properties.
    my $props = $self->properties;
    while (my ($prop, $val) = each %{ $props } ) {
        my $normalizer = $normalizer_for{$prop} or $self->usage(__x(
            'Unknown property "{property}"',
            property => $prop,
        ));
        push @vars => {
            key   => "$key.$prop",
            value => $normalizer->($val),
        };
    }

    # Make it so.
    $config->group_set( $config->local_file, \@vars );

    return $self;
}

sub _set {
    my ($self, $key, $name, $value) = @_;
    $self->usage unless $name && $value;

    my $config = $self->sqitch->config;
    my $target = "target.$name";

    hurl target => __x(
        'Unknown target "{target}"',
        target => $name
    ) unless $config->get( key => "$target.uri");

    $config->set(
        key      => "$target.$key",
        value    => $value,
        filename => $config->local_file,
    );
    return $self;
}

sub set_url { shift->set_uri(@_) };
sub set_uri {
    my ($self, $name, $uri) = @_;
    $self->_set(
        'uri',
        $name,
        $uri ? URI::db->new($uri, 'db:')->as_string : undef
    );
}

sub set_registry  { shift->_set('registry',  @_) }
sub set_client    { shift->_set('client',    @_) }
sub set_extension { shift->_set('extension', @_) }

sub _set_dir {
    my ($self, $key, $name, $dir) = @_;
    $self->_set( $key, $name, $normalizer_for{top_dir}->($dir) );
}

sub set_top_dir    { shift->_set_dir('top_dir',    @_) }
sub set_deploy_dir { shift->_set_dir('deploy_dir', @_) }
sub set_revert_dir { shift->_set_dir('revert_dir', @_) }
sub set_verify_dir { shift->_set_dir('verify_dir', @_) }

sub set_plan_file {
    my ($self, $name, $file) = @_;
    $self->_set( 'plan_file', $name, $normalizer_for{plan_file}->($file) );
}

sub rm { shift->remove(@_) }
sub remove {
    my ($self, $name) = @_;
    $self->usage unless $name;
    if ( my @deps = $self->_dependencies($name) ) {
        hurl target => __x(
            q{Cannot rename target "{target}" because it's refereneced by: {engines}},
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
            q{Cannot rename target "{target}" because it's refereneced by: {engines}},
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
    return $self;
}

sub show {
    my ($self, @names) = @_;
    return $self->list unless @names;
    my $sqitch = $self->sqitch;
    my $config = $sqitch->config;

    # Set up labels.
    my $len = max map { length } (
        __ 'URI',
        __ 'Registry',
        __ 'Client',
        __ 'Top Directory',
        __ 'Plan File',
        __ 'Deploy Directory',
        __ 'Revert Directory',
        __ 'Verify Directory',
        __ 'Extension',
    );

    my %label_for = (
        uri      => __('URI')                . ': ' . ' ' x ($len - length __ 'URI'),
        registry => __('Registry')           . ': ' . ' ' x ($len - length __ 'Registry'),
        client   => __('Client')             . ': ' . ' ' x ($len - length __ 'Client'),
        top_dir    => __('Top Directory')    . ': ' . ' ' x ($len - length __ 'Top Directory'),
        plan_file  => __('Plan File')        . ': ' . ' ' x ($len - length __ 'Plan File'),
        deploy_dir => __('Deploy Directory') . ': ' . ' ' x ($len - length __ 'Deploy Directory'),
        revert_dir => __('Revert Directory') . ': ' . ' ' x ($len - length __ 'Revert Directory'),
        verify_dir => __('Verify Directory') . ': ' . ' ' x ($len - length __ 'Verify Directory'),
        extension  => __('Extension')        . ': ' . ' ' x ($len - length __ 'Extension'),
    );

    require App::Sqitch::Target;
    for my $name (@names) {
        my $target = App::Sqitch::Target->new(
            sqitch => $sqitch,
            name   => $name,
        );
        $self->emit("* $name");
        $self->emit('  ', $label_for{uri},        $target->uri->as_string);
        $self->emit('  ', $label_for{registry},   $target->registry);
        $self->emit('  ', $label_for{client},     $target->client);
        $self->emit('  ', $label_for{top_dir},    $target->top_dir);
        $self->emit('  ', $label_for{plan_file},  $target->plan_file);
        $self->emit('  ', $label_for{deploy_dir}, $target->deploy_dir);
        $self->emit('  ', $label_for{revert_dir}, $target->revert_dir);
        $self->emit('  ', $label_for{verify_dir}, $target->verify_dir);
        $self->emit('  ', $label_for{extension},  $target->extension);
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

=head3 C<list>

Implements the C<list> action.

=head3 C<remove>

=head3 C<rm>

Implements the C<remove> action.

=head3 C<rename>

Implements the C<rename> action.

=head3 C<set_client>

Implements the C<set-client> action.

=head3 C<set_registry>

Implements the C<set-registry> action.

=head3 C<set_uri>

=head3 C<set_url>

Implements the C<set-uri> action.

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

=head3 C<set_extension>

Implements the C<set-extension> action.

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

Copyright (c) 2012-2014 iovation Inc.

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
