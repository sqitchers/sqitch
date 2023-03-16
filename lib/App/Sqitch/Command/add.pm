package App::Sqitch::Command::add;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Moo;
use App::Sqitch::Types qw(Str Int ArrayRef HashRef Dir Bool Maybe);
use Path::Class;
use Try::Tiny;
use Clone qw(clone);
use List::Util qw(first);
use namespace::autoclean;

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ContextCommand';

# VERSION

has change_name => (
    is  => 'ro',
    isa => Maybe[Str],
);

has requires => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has conflicts => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has all => (
    is      => 'ro',
    isa     => Bool,
    default => 0
);

has note => (
    is       => 'ro',
    isa      => ArrayRef[Str],
    default  => sub { [] },
);

has variables => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'add.variables' );
    },
);

has template_directory => (
    is  => 'ro',
    isa => Maybe[Dir],
);

has template_name => (
    is  => 'ro',
    isa => Maybe[Str],
);

has with_scripts => (
    is       => 'ro',
    isa      => HashRef,
    default  => sub { {} },
);

has templates => (
    is       => 'ro',
    isa      => HashRef,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        $self->_config_templates($self->sqitch->config);
    },
);

has open_editor => (
    is       => 'ro',
    isa      => Bool,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get(
            key => 'add.open_editor',
            as  => 'bool',
        ) // 0;
    },
);

sub _check_script($) {
    my $file = file shift;

    hurl add => __x(
        'Template {template} does not exist',
        template => $file,
    ) unless -e $file;

    hurl add => __x(
        'Template {template} is not a file',
        template => $file,
    ) unless -f $file;

    return $file;
}

sub _config_templates {
    my ($self, $config) = @_;
    my $tmpl = $config->get_section( section => 'add.templates' );
    $_ = _check_script $_ for values %{ $tmpl };
    return $tmpl;
}

sub all_templates {
    my ($self, $name) = @_;
    my $config = $self->sqitch->config;
    my $tmpl   = $self->templates;

    # Read all the template directories.
    for my $dir (
        $self->template_directory,
        $config->user_dir->subdir('templates'),
        $config->system_dir->subdir('templates'),
    ) {
        next unless $dir && -d $dir;
        for my $subdir($dir->children) {
            next unless $subdir->is_dir;
            next if $tmpl->{my $script = $subdir->basename};
            my $file = $subdir->file("$name.tmpl");
            $tmpl->{$script} = $file if -f $file
        }
    }

    # Make sure we have core templates.
    my $with = $self->with_scripts;
    for my $script (qw(deploy revert verify)) {
        hurl add => __x(
            'Cannot find {script} template',
            script => $script,
        ) if !$tmpl->{$script} && ($with->{$script} || !exists $with->{$script});
    }

    return $tmpl;
}

sub options {
    return qw(
        change-name|change|c=s
        requires|r=s@
        conflicts|x=s@
        note|n|m=s@
        all|a!
        template-name|template|t=s
        template-directory=s
        with=s@
        without=s@
        use=s%
        open-editor|edit|e!
    );
}

# Override to convert multiple vars to an array.
sub _parse_opts {
    my ( $class, $args ) = @_;

    my (%opts, %vars);
    Getopt::Long::Configure(qw(bundling no_pass_through));
    Getopt::Long::GetOptionsFromArray(
        $args, \%opts,
        $class->options,
        'set|s=s%' => sub {
            my ($opt, $key, $val) = @_;
            if (exists $vars{$key}) {
                $vars{$key} = [$vars{$key}] unless ref $vars{$key};
                push @{ $vars{$key} } => $val;
            } else {
                $vars{$key} = $val;
            }
        }
    ) or $class->usage;
    $opts{set} = \%vars if %vars;

    # Convert dashes to underscores.
    for my $k (keys %opts) {
        next unless ( my $nk = $k ) =~ s/-/_/g;
        $opts{$nk} = delete $opts{$k};
    }

    # Merge with and without.
    $opts{with_scripts} = {
        ( map { $_ => 1 } qw(deploy revert verify) ),
        ( map { $_ => 1 } @{ delete $opts{with}    || [] } ),
        ( map { $_ => 0 } @{ delete $opts{without} || [] } ),
    };
    return \%opts;
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = (
        requires  => $opt->{requires}  || [],
        conflicts => $opt->{conflicts} || [],
        note      => $opt->{note}      || [],
    );

    for my $key (qw(with_scripts change_name)) {
        $params{$key} = $opt->{$key} if $opt->{$key};
    }

    if (
        my $dir = $opt->{template_directory}
            || $config->get( key => 'add.template_directory' )
    ) {
        $dir = $params{template_directory} = dir $dir;
        hurl add => __x(
            'Directory "{dir}" does not exist',
            dir => $dir,
        ) unless -e $dir;

        hurl add => __x(
            '"{dir}" is not a directory',
            dir => $dir,
        ) unless -d $dir;
    }

    if (
        my $name = $opt->{template_name}
            || $config->get( key => 'add.template_name' )
    ) {
        $params{template_name} = $name;
    }

    # Merge variables.
    if ( my $vars = $opt->{set} ) {
        $params{variables} = {
            %{ $config->get_section( section => 'add.variables' ) },
            %{ $vars },
        };
    }

    # Merge template info.
    my $tmpl = $class->_config_templates($config);
    if ( my $use = delete $opt->{use} ) {
        while (my ($k, $v) = each %{ $use }) {
            $tmpl->{$k} = _check_script $v;
        }
    }
    $params{templates} = $tmpl if %{ $tmpl };

    # Copy other options.
    for my $key (qw(all open_editor)) {
        $params{$key} = $opt->{$key} if exists $opt->{$key};
    }

    return \%params;
}

sub execute {
    my $self = shift;
    $self->usage unless @_ || $self->change_name;

    my ($name, $targets) = $self->parse_args(
        names      => [$self->change_name],
        all        => $self->all,
        args       => \@_,
        no_changes => 1,
    );

    # Check for missing name.
    unless (defined $name) {
        if (my $target = first { my $n = $_->name; first { $_ eq $n } @_ } @{ $targets }) {
            # Name conflicts with a target.
            hurl add => __x(
                'Name "{name}" identifies a target; use "--change {name}" to use it for the change name',
                name => $target->name,
            );
        }
        $self->usage;
    }

    my $note = join "\n\n", => @{ $self->note };
    my ($first_change, %added, @files, %seen);

    for my $target (@{ $targets }) {
        my $plan = $target->plan;
        my $with = $self->with_scripts;
        my $tmpl = $self->all_templates($self->template_name || $target->engine_key);
        my $file = $plan->file;
        my $spec = $added{$file} ||= { scripts => [], seen => {} };
        my $change = $spec->{change};
        if ($change) {
            # Need a dupe for *this* target so script names are right.
            $change = ref($change)->new(
                plan => $plan,
                name => $change->name,
            );
        } else {
            $change = $spec->{change} = $plan->add(
                name      => $name,
                requires  => $self->requires,
                conflicts => $self->conflicts,
                note      => $note,
            );
            $first_change ||= $change;
        }

        # Suss out the files we'll need to write.
        push @{ $spec->{scripts} } => map {
            push @files => $_->[1] unless $seen{$_->[1]}++;
            [ $_->[1], $tmpl->{ $_->[0] }, $target->engine_key, $plan->project ];
        } grep {
            !$spec->{seen}{ $_->[1] }++;
        } map {
            [$_ => $change->script_file($_)];
        } grep {
            !exists $with->{$_} || $with->{$_}
        } sort keys %{ $tmpl };
    }

    # Make sure we have a note.
    $note = $first_change->request_note(
        for     => __ 'add',
        scripts => \@files,
    );

    # Time to write everything out.
    for my $target (@{ $targets }) {
        my $plan = $target->plan;
        my $file = $plan->file;
        my $spec = delete $added{$file} or next;

        # Write out the scripts.
        $self->_add($name, @{ $_ }) for @{ $spec->{scripts} };

        # We good. Set the note on all changes and write out the plan files.
        my $change = $spec->{change};
        $change->note($note);
        $plan->write_to( $plan->file );
        $self->info(__x(
            'Added "{change}" to {file}',
            change => $spec->{change}->format_op_name_dependencies,
            file   => $plan->file,
        ));
    }

    # Let 'em at it.
    if ($self->open_editor) {
        my $sqitch = $self->sqitch;
        $sqitch->shell( $sqitch->editor . ' ' . $sqitch->quote_shell(@files) );
    }

    return $self;
}

sub _add {
    my ( $self, $name, $file, $tmpl, $engine, $project ) = @_;
    if (-e $file) {
        $self->info(__x(
            'Skipped {file}: already exists',
            file => $file,
        ));
        return $self;
    }

    # Create the directory for the file, if it does not exist.
    $self->_mkpath($file->dir->stringify);

    my $vars = clone {
        %{ $self->variables },
        change    => $name,
        engine    => $engine,
        project   => $project,
        requires  => $self->requires,
        conflicts => $self->conflicts,
    };

    my $fh = $file->open('>:utf8_strict') or hurl add => __x(
        'Cannot open {file}: {error}',
        file  => $file,
        error => $!
    );

    if (eval 'use Template; 1') {
        my $tt = Template->new;
        $tt->process( $self->_slurp($tmpl), $vars, $fh ) or hurl add => __x(
            'Error executing {template}: {error}',
            template => $tmpl,
            error    => $tt->error,
        );
    } else {
        eval 'use Template::Tiny 0.11; 1' or die $@;
        my $output = '';
        Template::Tiny->new->process( $self->_slurp($tmpl), $vars, \$output );
        print $fh $output;
    }

    close $fh or hurl add => __x(
        'Error closing {file}: {error}',
        file  => $file,
        error => $!
    );
    
    # Warn if the file name has a double extension
    if ($file =~ m/\.(\w+)\.\w+$/) {
        my $ext = $1;
        $self->warning(__x(
            'Warning: file {file} has a double extension of {ext}',
            file => $file,
            ext  => $ext,
        ));
    }
    
    $self->info(__x 'Created {file}', file => $file);
}

sub _slurp {
    my ( $self, $tmpl ) = @_;
    open my $fh, "<:utf8_strict", $tmpl or hurl add => __x(
        'Cannot open {file}: {error}',
        file  => $tmpl,
        error => $!
    );
    local $/;
    return \<$fh>;
}

1;

__END__

=head1 Name

App::Sqitch::Command::add - Add a new change to Sqitch plans

=head1 Synopsis

  my $cmd = App::Sqitch::Command::add->new(%params);
  $cmd->execute;

=head1 Description

Adds a new deployment change. This will result in the creation of a scripts in
the deploy, revert, and verify directories. The scripts are based on
L<Template::Tiny> templates in F<~/.sqitch/templates/> or
C<$(prefix)/etc/sqitch/templates> (call C<sqitch --etc-path> to find out
where, exactly (e.g., C<$(sqitch --etc-path)/sqitch.conf>).

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::add->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<add> command.

=head3 C<configure>

  my $params = App::Sqitch::Command::add->configure(
      $config,
      $options,
  );

Processes the configuration and command options and returns a hash suitable
for the constructor.

=head2 Attributes

=head3 C<change_name>

The name of the change to be added.

=head3 C<note>

Text of the change note.

=head3 C<requires>

List of required changes.

=head3 C<conflicts>

List of conflicting changes.

=head3 C<all>

Boolean indicating whether or not to run the command against all plans in the
project.

=head3 C<template_name>

The name of the templates to use when generating scripts. Defaults to the
engine for which the scripts are being generated.

=head3 C<template_directory>

Directory in which to find the change script templates.

=head3 C<with_scripts>

Hash reference indicating which scripts to create.

=head2 Instance Methods

=head3 C<execute>

  $add->execute($command);

Executes the C<add> command.

=head3 C<all_templates>

Returns a hash reference of script names mapped to template files for all
scripts that should be generated for the new change.

=head1 See Also

=over

=item L<sqitch-add>

Documentation for the C<add> command to the Sqitch command-line client.

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
