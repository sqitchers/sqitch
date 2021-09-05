package App::Sqitch::Command::init;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(URI Maybe);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use List::MoreUtils qw(natatime);
use Path::Class;
use App::Sqitch::Plan;
use namespace::autoclean;
use constant extra_target_keys => qw(engine target);

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::TargetConfigCommand';

# VERSION

sub execute {
    my ( $self, $project ) = @_;
    $self->_validate_project($project);
    $self->write_config;
    my $target = $self->config_target;
    $self->write_plan(
        project => $project,
        uri     => $self->uri,
        target  => $target,
    );
    $self->make_directories_for($target);
    return $self;
}

has uri => (
    is  => 'ro',
    isa => Maybe[URI],
);

sub options {
    return qw(uri=s);
}

sub _validate_project {
    my ( $self, $project ) = @_;
    $self->usage unless $project;
    my $name_re = 'App::Sqitch::Plan'->name_regex;
    hurl init => __x(
        qq{invalid project name "{project}": project names must not }
        . 'begin with punctuation, contain "@", ":", "#", or blanks, or end in '
        . 'punctuation or digits following punctuation',
        project => $project
    ) unless $project =~ /\A$name_re\z/;
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    if ( my $uri = $opt->{uri} ) {
        require URI;
        $opt->{uri} = 'URI'->new($uri);
    }

    return $opt;
}

sub write_config {
    my $self    = shift;
    my $sqitch  = $self->sqitch;
    my $config  = $sqitch->config;
    my $file    = $config->local_file;
    if ( -f $file ) {

        # Do nothing? Update config?
        return $self;
    }

    my ( @vars, @comments );

    # Get the props, and make sure the target can find the engine.
    my $props  = $self->properties;
    my $target = $self->config_target;

    # Write the engine from --engine or core.engine.
    my $ekey   = $props->{engine} || $target->engine_key;
    if ($ekey) {
        push @vars => {
            key   => "core.engine",
            value => $ekey,
        };
    }
    else {
        push @comments => "\tengine = ";
    }

    # Add core properties.
    for my $name (qw(
        plan_file
        top_dir
    )) {
        # Set properties passed on the command-line.
        if ( my $val = $props->{$name} ) {
            push @vars => {
                key   => "core.$name",
                value => $val,
            };
        }
        else {
            my $val //= $target->$name // '';
            push @comments => "\t$name = $val";
        }
    }

    # Add script options passed to the init command. No comments if not set.
    for my $attr (qw(
        extension
        deploy_dir
        revert_dir
        verify_dir
        reworked_dir
        reworked_deploy_dir
        reworked_revert_dir
        reworked_verify_dir
    )) {
        push @vars => { key => "core.$attr", value => $props->{$attr} }
            if defined $props->{$attr};
    }

    # Add variables.
    if (my $vars = $props->{variables}) {
        push @vars => map {{
            key   => "core.variables.$_",
            value => $vars->{$_},
        }} keys %{ $vars };
    }

    # Emit them.
    if (@vars) {
        $config->group_set( $file => \@vars );
    }
    else {
        unshift @comments => '[core]';
    }

    # Emit the comments.
    $config->add_comment(
        filename => $file,
        indented => 1,
        comment  => join "\n" => @comments,
    ) if @comments;

    if ($ekey) {
        # Write out the engine.$engine section.
        my $config_key  = "engine.$ekey";
        @comments = @vars = ();

        for my $key (qw(target registry client)) {
            # Was it passed as an option?
            if ( my $val = $props->{$key} ) {
                push @vars => {
                    key   => "$config_key.$key",
                    value => $val,
                };
                # We're good on this one.
                next;
            }

            # No value, but add it as a comment, possibly with a default.
            my $def = $target->$key
                // $config->get( key => "$config_key.$key" )
                // '';
            push @comments => "\t$key = $def";
        }

        if (@vars) {
            # Emit them.
            $config->group_set( $file => \@vars ) if @vars;
        }
        else {
            # Still want the section, emit it as a comment.
            unshift @comments => qq{[engine "$ekey"]};
        }

        # Emit the comments.
        $config->add_comment(
            filename => $file,
            indented => 1,
            comment  => join "\n" => @comments,
        ) if @comments;
    }

    # Is there are target?
    if (my $target_name = $props->{target}) {
        # If it's a named target, add it to the configuration.
        $config->set(
            filename => $file,
            key      => "target.$target_name.uri",
            value    => $target->uri,
        ) if $target_name !~ /:/
    }

    $self->info( __x 'Created {file}', file => $file );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::init - Initialize a Sqitch project

=head1 Synopsis

  my $cmd = App::Sqitch::Command::init->new(%params);
  $cmd->execute;

=head1 Description

This command creates the files and directories for a new Sqitch project -
basically a F<sqitch.conf> file and directories for deploy and revert
scripts.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::init->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<config> command.

=head3 C<extra_target_keys>

Returns a list of additional option keys to be specified via options.

=head2 Attributes

=head3 C<uri>

URI for the project.

=head3 C<properties>

Hash of property values to set.

=head2 Instance Methods

=head3 C<execute>

  $init->execute($project);

Executes the C<init> command.

=head3 C<write_config>

  $init->write_config;

Writes out the configuration file. Called by C<execute()>.

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2021 iovation Inc.

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

