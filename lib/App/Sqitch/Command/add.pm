package App::Sqitch::Command::add;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use Mouse;
use MouseX::Types::Path::Class;
use Path::Class;
use Try::Tiny;
use File::Path qw(make_path);
use Clone qw(clone);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.991';

has requires => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

has conflicts => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

has note => (
    is       => 'ro',
    isa      => 'ArrayRef[Str]',
    required => 1,
    default  => sub { [] },
);

has variables => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        shift->sqitch->config->get_section( section => 'add.variables' );
    },
);

has template_directory => (
    is  => 'ro',
    isa => 'Maybe[Path::Class::Dir]',
);

has template_name => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
    lazy     => 1,
    default  => sub { shift->sqitch->_engine },
);

has with_scripts => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    default  => sub { {} },
);

has templates => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        $self->_config_templates($self->sqitch->config);
    },
);

has open_editor => (
    is       => 'ro',
    isa      => 'Bool',
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

    # Get legacy config.
    for my $script (qw(deploy revert verify)) {
        next if $tmpl->{$script};
        if (my $file = $config->get( key => "add.$script\_template")) {
            $tmpl->{$script} = _check_script $file;
        }
    }
    return $tmpl;
}

sub all_templates {
    my $self   = shift;
    my $config = $self->sqitch->config;
    my $name   = $self->template_name;
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
        requires|r=s@
        conflicts|c=s@
        note|n|m=s@
        template-name|template|t=s
        template-directory=s
        with=s@
        without=s@
        use=s%
        open-editor|edit|e!

        deploy-template=s
        revert-template=s
        verify-template=s
        deploy!
        revert!
        verify!
    );
    # Those last six are deprecated.
}

# Override to convert multiple vars to an array.
sub _parse_opts {
    my ( $class, $args ) = @_;
    return {} unless $args && @{$args};

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
        ( map { $_ => delete $opts{$_} // 1 } qw(deploy revert verify) ),
        ( map { $_ => 1 } @{ delete $opts{with}    || [] } ),
        ( map { $_ => 0 } @{ delete $opts{without} || [] } ),
    };

    # Merge deprecated use options.
    for my $script (qw(deploy revert verify)) {
        next unless exists $opts{"$script\_template"};
        $opts{use} ||= {};
        $opts{use}{$script} = delete $opts{"$script\_template"}
    }

    return \%opts;
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = (
        requires  => $opt->{requires}  || [],
        conflicts => $opt->{conflicts} || [],
        note      => $opt->{note}      || [],
    );

    $params{with_scripts} = $opt->{with_scripts} if $opt->{with_scripts};

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

    $params{open_editor} = $opt->{open_editor} if exists $opt->{open_editor};

    return \%params;
}

sub execute {
    my ( $self, $name ) = @_;
    $self->usage unless defined $name;
    my $sqitch = $self->sqitch;
    my $plan   = $sqitch->plan;
    my $with   = $self->with_scripts;
    my $tmpl   = $self->all_templates;
    my $change = $plan->add(
        name      => $name,
        requires  => $self->requires,
        conflicts => $self->conflicts,
        note      => join "\n\n" => @{ $self->note },
    );

    my @scripts = grep {
        !exists $with->{$_} || $with->{$_}
    } sort keys %{ $tmpl };
    my @files = map { $change->script_file($_ ) } @scripts;

    # Make sure we have a note.
    $change->request_note(
        for     => __ 'add',
        scripts => \@files,
    );

    # Add the scripts.
    my $i = 0;
    $self->_add( $name, $files[$i++], $tmpl->{$_} ) for @scripts;

    # We good, write the plan file back out.
    $plan->write_to( $sqitch->plan_file );
    $self->info(__x(
        'Added "{change}" to {file}',
        change => $change->format_op_name_dependencies,
        file   => $sqitch->plan_file,
    ));

    # Let 'em at it.
    if ($self->open_editor) {
        $sqitch->shell( $sqitch->editor . ' ' . $sqitch->quote_shell(@files) );
    }

    return $self;
}

sub _add {
    my ( $self, $name, $file, $tmpl ) = @_;
    if (-e $file) {
        $self->info(__x(
            'Skipped {file}: already exists',
            file => $file,
        ));
        return $self;
    }

    # Create the directory for the file, if it does not exist.
    make_path $file->dir->stringify, { error => \my $err };
    if ( my $diag = shift @{ $err } ) {
        my ( $path, $msg ) = %{ $diag };
        hurl add => __x(
            'Error creating {path}: {error}',
            path  => $path,
            error => $msg,
        ) if $path;
        hurl add => $msg;
    }

    my $vars = clone {
        %{ $self->variables },
        change    => $name,
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

App::Sqitch::Command::add - Add a new change to a Sqitch plan

=head1 Synopsis

  my $cmd = App::Sqitch::Command::add->new(%params);
  $cmd->execute;

=head1 Description

Adds a new deployment change. This will result in the creation of a scripts in
the deploy, revert, and verify directories. The scripts are based on
L<Template::Tiny> templates in F<~/.sqitch/templates/> or
C<$(etc_path)/templates>.

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

=head2 Instance Methods

=head3 C<execute>

  $add->execute($command);

Executes the C<add> command.

=head2 C<all_templates>

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

Copyright (c) 2012-2013 iovation Inc.

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
