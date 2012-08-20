package App::Sqitch::Command::init;

use v5.10.1;
use strict;
use warnings;
use utf8;
use Moose;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use File::Path qw(make_path);
use Path::Class;
use Try::Tiny;
use App::Sqitch::Plan;
use Moose::Util::TypeConstraints;
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.901';

sub execute {
    my ( $self, $project ) = @_;
    $self->_validate_project($project);
    $self->write_config;
    $self->write_plan($project);
    $self->make_directories;
    return $self;
}

has uri => (
    is       => 'ro',
    isa      => 'Maybe[URI]',
    required => 0,
);

sub options {
    return qw(
        uri=s
    );
}

sub _validate_project {
    my ( $self, $project ) = @_;
    $self->usage unless $project;
    my $name_re = App::Sqitch::Plan->name_regex;
    hurl init => __x(
        qq{invalid project name "{project}": project names must not }
        . 'begin with punctuation, contain "@" or ":", or end in '
        . 'punctuation or digits following punctuation',
        project => $project
    ) unless $project =~ /\A$name_re\z/;
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    if ( my $uri = $opt->{uri} ) {
        require URI;
        $opt->{uri} = URI->new($uri);
    }

    return $opt;
}

sub make_directories {
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $sep    = dir('')->stringify; # OS-specific directory separator.
    for my $attr (qw(deploy_dir revert_dir test_dir)) {
        my $dir = $sqitch->$attr;
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
    return $self;
}

sub write_plan {
    my ( $self, $project ) = @_;
    my $sqitch = $self->sqitch;
    my $file   = $sqitch->plan_file;
    return $self if -f $file;

    my $fh = $file->open('>:encoding(UTF-8)') or hurl init => __x(
        'Cannot open {file}: {error}',
        file => $file,
        error => $!,
    );
    require App::Sqitch::Plan;
    $fh->print(
        '%syntax-version=', App::Sqitch::Plan::SYNTAX_VERSION(), $/,
        '%project=', $project, $/,
        ( $self->uri ? ('%uri=', $self->uri->canonical, $/) : () ), $/,
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
    my $self   = shift;
    my $sqitch = $self->sqitch;
    my $meta   = $sqitch->meta;
    my $config = $sqitch->config;
    my $file   = $config->local_file;
    if ( -f $file ) {

        # Do nothing? Update config?
        return $self;
    }

    my ( @vars, @comments );

    # Write the engine.
    my $engine = try { $sqitch->engine };
    if ($engine) {
        push @vars => {
            key   => "core.engine",
            value => $engine->name,
        };
    }
    else {
        push @comments => "\tengine = ";
    }

    # Add in the other stuff.
    for my $name (qw(
        plan_file
        top_dir
        deploy_dir
        revert_dir
        test_dir
        extension
    )) {

        # Set core attributes that are not their default values and not
        # already in user or system config.
        my $attr = $meta->find_attribute_by_name($name)
            or hurl "Cannot find App::Sqitch attribute $name";
        my $val = $attr->get_value($sqitch);
        my $def = $attr->default($sqitch);
        my $var = $config->get( key => "core.$name" );

        no warnings 'uninitialized';
        if ( $val ne $def && $val ne $var ) {

            # It was specified on the command-line, so grab it to write out.
            push @vars => {
                key   => "core.$name",
                value => $val,
            };
        }
        else {
            $var //= $def // '';
            push @comments => "\t$name = $var";
        }
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

    if ($engine) {

        # Write out the core.$engine section.
        my $ekey        = 'core.' . $engine->name;
        my %config_vars = $engine->config_vars;
        my $emeta       = $engine->meta;
        @comments = @vars = ();

        while ( my ( $key, $type ) = each %config_vars ) {

            # Was it passed as an option?
            my $core_key = $key =~ /^db_/ ? $key : "db_$key";
            if ( my $attr = $meta->find_attribute_by_name($core_key) ) {
                if ( my $val = $attr->get_value($sqitch) ) {

                    # It was passed as an option, so record that.
                    my $multiple = $type =~ s/[+]$//;
                    $type = undef if $type eq 'any';
                    push @vars => {
                        key      => "$ekey.$key",
                        value    => $val,
                        as       => $type,
                        multiple => $multiple,
                    };

                    # We're good on this one.
                    next;
                }
            }

            # No value, but add it as a comment.
            if ( my $attr = $emeta->find_attribute_by_name($key) ) {

                # Add it as a comment, possibly with a default.
                my $def = $attr->default($engine)
                    // $config->get( key => "$ekey.$key" )
                    // '';
                push @comments => "\t$key = $def";
            }
            else {

                # Add it as a comment, with the config, if possible.
                my $val = $config->get( key => "$ekey.$key" ) // '';
                push @comments => "\t$key = $val";
            }
        }

        if (@vars) {

            # Emit them.
            $config->group_set( $file => \@vars ) if @vars;
        }
        else {

            # Still want the section, emit it as a comment.
            unshift @comments => '[core "' . $engine->name . '"]';
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

__PACKAGE__->meta->make_immutable;
no Moose;

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

Copyright (c) 2012 iovation Inc.

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

