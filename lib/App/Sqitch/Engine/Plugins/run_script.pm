package App::Sqitch::Engine::Plugins::run_script;
use Moo;
use App::Sqitch::Types qw(Dir Str Int Change Sqitch Plan Bool HashRef URI Maybe);
use App::Sqitch::X qw(hurl);

#setup triggers in BUILD

has _sqitch => (is=>'rw', isa=> Sqitch,documentation => 'Pointer to sqitch');

has _change =>(is=>'rw', isa=>Change,documentation =>'Pointer to current change');

has after_verif_dir => (
    is       => 'ro',
    isa      => Dir,
    lazy     => 1,
    default  => sub { shift->_build_dirs('after_verif')},
    documetation => 'Contains after_deploy path, defaults to after_deploy, or uses key core.after_deploy_dir'
);

has after_revert_dir => (
    is       => 'ro',
    isa      => Dir,
    lazy     => 1,
    default  => sub { shift->_build_dirs('after_revert')},
    documetation => 'Contains after_revert path, defaults to after_revert, or uses key core.after_revert_dir'
);

has after_deploy_dir => (
    is       => 'ro',
    isa      => Dir,
    lazy     => 1,
    default  => sub { shift->_build_dirs('after_deploy')},
    documetation => 'Contains after_deploy path, defaults to after_deploy, or uses key core.after_deploy_dir'
);

sub _build_dirs 
{
    my $self=shift;
    my $type=shift; # what type of dir to build
    if ( my $dir = $self->_sqitch->config->get( key => 'core.'.$type.'_dir' ) ) {
            return dir $dir;
        }
        my $dir=$self->_sqitch->top_dir->subdir($type)->cleanup;
        return $dir;
}

=method deploy_file

Returns the file to be executed

=cut

sub deploy_file
{
    my $self=shift;
    use File::Basename;
    my ($filename,undef,undef)=fileparse($self->_change->path_segments,qr/\.[^.*]*/);
    my $file=$self->after_deploy_dir->file($filename);
    return $file;

}

=method revert_file

Returns the file to be executed during revert phase

=cut

sub revert_file
{
    my $self=shift;
    use File::Basename;
    my $file=$self->after_deploy_dir->file(fileparse($self->_change->path_segments,qr/\.[^.*]*/));
    return $file;

}

=method verify_file

Returns the file to be executed during verify phase

=cut

sub verify_file
{
    my $self=shift;
    use File::Basename;
    my $file=$self->after_deploy_dir->file(fileparse($self->_change->path_segments,qr/\.[^.*]*/));
    return $file;

}

=method run_verify

Runs the run_verify task

=cut

sub run_verify {
    my $self   = shift;
    my $class  = shift;
    $self->_change(shift);
    if (-f $self->verify_file)
    {
        system($self->verify_file) and hurl $self->verify_file." failed";;
    }
}


=method run_deploy

Runs the run_deploy task

=cut

sub run_deploy {
    my $self   = shift;
    my $class  = shift;
    $self->_change(shift);
    print "DEBUG:::",$self->deploy_file."\n";
    if (-f $self->deploy_file)
    {
        system($self->deploy_file) and hurl $self->deploy_file." failed";
    }
}

=method run_revert

Runs the run_revert task

=cut


sub run_revert {
    my $self   = shift;
    my $class = shift;
    $self->_change(shift);
    if (-f $self->revert_file)
    {
        system($self->revert_file) and hurl $self->revert_file." failed";;
    }
}

sub init {
    my $self  = shift;
    my $class = shift;
    $self->_sqitch($class->sqitch);
}

sub _add {
    my $self = shift;
    my $func = shift;
    App::Sqitch::Engine->add_trigger( $func => sub { $self->$func(@_) } );
}

# Associates triggers if the function in the foreach statement exists in the current class
sub BUILD  {
    my $self = shift;

    foreach my $trigger (qw(init run_verify run_deploy run_revert))
    {
        if ($self->can($trigger))
        {
            $self->_add($trigger);
        }
    }
}

#initializes the package when found by module builder.
__PACKAGE__->new();
1;
