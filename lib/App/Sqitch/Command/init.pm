package App::Sqitch::Command::init;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::Types qw(URI Maybe);
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Path qw(make_path);
use List::MoreUtils qw(natatime);
use Path::Class;
use Try::Tiny;
use App::Sqitch::Plan;
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ScriptConfigCommand';

our $VERSION = '0.9993';

sub execute {
    my ( $self, $project ) = @_;
    $self->_validate_project($project);
    $self->write_config;
    $self->write_plan($project);
    $self->make_directories;
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

sub make_directories {
    my $self   = shift;
    for my $dir ($self->directories_for( $self->default_target )) {
        $self->_mkdir($dir) unless -e $dir;
    }
    return $self;
}

sub _mkdir {
    my ( $self, $dir ) = @_;
    my $sep    = dir('')->stringify; # OS-specific directory separator.
    $self->info(__x(
        'Created {file}',
        file => "$dir$sep"
    )) if make_path $dir, { error => \my $err };
    if ( my $diag = shift @{ $err } ) {
        my ( $path, $msg ) = %{ $diag };
        hurl init => __x(
            'Error creating {path}: {error}',
            path  => $path,
            error => $msg,
        ) if $path;
        hurl init => $msg;
    }
}

sub write_plan {
    my ( $self, $project ) = @_;
    my $target = $self->default_target;
    my $file   = $target->plan_file;

    if (-e $file) {
        hurl init => __x(
            'Cannot initialize because {file} already exists and is not a file',
            file => $file,
        ) unless -f $file;

        # Try to load the plan file.
        my $plan = App::Sqitch::Plan->new(
            sqitch => $self->sqitch,
            file   => $file,
            target => $self->default_target,
        );
        my $file_proj = try { $plan->project } or hurl init => __x(
            'Cannot initialize because {file} already exists and is not a valid plan file',
            file => $file,
        );

        # Bail if this plan file looks like it's for a different project.
        hurl init => __x(
            'Cannot initialize because project "{project}" already initialized in {file}',
            project => $plan->project,
            file    => $file,
        ) if $plan->project ne $project;
        return $self;
    }

    $self->_mkdir( $file->dir ) unless -d $file->dir;

    my $fh = $file->open('>:utf8_strict') or hurl init => __x(
        'Cannot open {file}: {error}',
        file => $file,
        error => $!,
    );
    require App::Sqitch::Plan;
    $fh->print(
        '%syntax-version=', App::Sqitch::Plan::SYNTAX_VERSION(), "\n",
        '%project=', "$project\n",
        ( $self->uri ? ('%uri=', $self->uri->canonical, "\n") : () ), "\n",
    );
    $fh->close or hurl add => __x(
        'Error closing {file}: {error}',
        file  => $file,
        error => $!
    );

    $self->info( __x 'Created {file}', file => $file );
    return $self;
}

sub write_config {
    my $self    = shift;
    my $sqitch  = $self->sqitch;
    my $config  = $sqitch->config;
    my $options = $sqitch->options;
    my $target  = $self->default_target;
    my $file    = $config->local_file;
    if ( -f $file ) {

        # Do nothing? Update config?
        return $self;
    }

    my ( @vars, @comments );

    # Write the engine from --engine or core.engine.
    my $ekey = $target->engine_key;
    if ($ekey) {
        push @vars => {
            key   => "core.engine",
            value => $ekey,
        };
    }
    else {
        push @comments => "\tengine = ";
    }

    # Add in the other stuff.
    for my $name (qw(
        plan_file
        top_dir
    )) {
        # Set core attributes that are not their default values and not
        # already in user or system config.
        my $val = $options->{$name};
        my $var = $config->get( key => "core.$name" );

        if ( $val && $val ne ($var // '') ) {
            # It was specified on the command-line, so grab it to write out.
            push @vars => {
                key   => "core.$name",
                value => $val,
            };
        }
        elsif ($name !~ /(?<!top)_dir$/) {
            $var //= $target->$name // '';
            push @comments => "\t$name = $var";
        }
    }

    # Add in options passed to the init command.
    my $dirs = $self->directories;
    while (my ($attr, $val) = each %{ $dirs }) {
        push @vars => { key => "core.$attr\_dir", value => $val };
    }
    if (my $ext = $self->extension) {
        push @vars => { key => 'core.extension', value => $ext };
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
            if ( my $val = $options->{$key} ) {

                # It was passed as an option, so record that.
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

=head2 Attributes

=head3 C<uri>

URI for the project.

=head2 Instance Methods

=head3 C<execute>

  $init->execute($project);

Executes the C<init> command.

=head3 C<make_directories>

  $init->make_directories;

Creates the deploy and revert directories.

=head3 C<write_config>

  $init->write_config;

Writes out the configuration file. Called by C<execute()>.

=head3 C<write_plan>

  $init->write_plan($project);

Writes out the plan file. Called by C<execute()>.

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

