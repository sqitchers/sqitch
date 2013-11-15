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

our $VERSION = '0.983';

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

for my $script (qw(deploy revert verify)) {
    has "with_$script" => (
        is      => 'ro',
        isa     => 'Bool',
        lazy    => 1,
        default => sub {
            shift->sqitch->config->get(
                key => "add.with_$script",
                as  => 'bool',
            ) // 1;
        }
    );

    has "$script\_template" => (
        is      => 'ro',
        isa     => 'Path::Class::File',
        lazy    => 1,
        default => sub { shift->_find($script) },
    );
}

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

sub _find {
    my ( $self, $script ) = @_;
    my $config = $self->sqitch->config;
    my $name   = $self->template_name;
    $config->get( key => "add.$script\_template" ) || do {
        for my $dir (
            $self->template_directory,
            $config->user_dir->subdir('templates'),
            $config->system_dir->subdir('templates'),
        ) {
            next unless $dir;
            my $tmpl = $dir->file($script, "$name.tmpl");
            return $tmpl if -f $tmpl;
        }
        hurl add => __x(
            'Cannot find {script} template',
            script => $script,
        );
    };
}

sub options {
    return qw(
        requires|r=s@
        conflicts|c=s@
        note|n|m=s@
        template-name|template|t=s
        template-directory=s
        deploy-template=s
        revert-template=s
        verify-template|test-template=s
        deploy!
        revert!
        verify|test!
        open-editor|edit|e!
    );
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

    # Convert dashes to underscores.
    for my $k (keys %opts) {
        next unless ( my $nk = $k ) =~ s/-/_/g;
        $opts{$nk} = delete $opts{$k};
    }

    $opts{set} = \%vars if %vars;
    return \%opts;
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params = (
        requires  => $opt->{requires}  || [],
        conflicts => $opt->{conflicts} || [],
        note      => $opt->{note}      || [],
    );

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

    for my $attr (qw(deploy revert verify)) {
        $params{"with_$attr"} = $opt->{$attr} if exists $opt->{$attr};
        my $t = "$attr\_template";
        $params{$t} = file $opt->{$t} if $opt->{$t};
    }

    if ( my $vars = $opt->{set} ) {
        # Merge with config.
        $params{variables} = {
            %{ $config->get_section( section => 'add.variables' ) },
            %{ $vars },
        };
    }

    $params{open_editor} = $opt->{open_editor} if exists $opt->{open_editor};

    return \%params;
}

sub execute {
    my ( $self, $name ) = @_;
    $self->usage unless defined $name;
    my $sqitch = $self->sqitch;
    my $plan   = $sqitch->plan;
    my $change = $plan->add(
        name      => $name,
        requires  => $self->requires,
        conflicts => $self->conflicts,
        note      => join "\n\n" => @{ $self->note },
    );

    my @files = (
        ($self->with_deploy ? $change->deploy_file : ()),
        ($self->with_revert ? $change->revert_file : ()),
        ($self->with_verify ? $change->verify_file : ()),
    );

    # Make sure we have a note.
    $change->request_note(
        for     => __ 'add',
        scripts => \@files,
    );

    $self->_add(
        $name,
        $change->deploy_file,
        $self->deploy_template,
    ) if $self->with_deploy;

    $self->_add(
        $name,
        $change->revert_file,
        $self->revert_template,
    ) if $self->with_revert;

    $self->_add(
        $name,
        $change->verify_file,
        $self->verify_template,
    ) if $self->with_verify;

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
