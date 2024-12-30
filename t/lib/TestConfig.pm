package TestConfig;
use strict;
use warnings;
use base 'App::Sqitch::Config';
use Path::Class;

BEGIN {
    # Suppress warnings from Locale::Messages.
    # https://github.com/gflohr/libintl-perl/issues/14
    use Locale::Messages;
    if ($Locale::Messages::package eq 'gettext_pp') {
        no warnings qw(redefine prototype);
        no strict 'refs';
        my $orig = \&Locale::gettext_pp::__locale_category;
        *{"Locale::gettext_pp::__locale_category"} = sub {
            local $SIG{__WARN__} = sub {};
            $orig->();
        }
    }
}

# Creates and returns a new TestConfig, which inherits from
# App::Sqitch::Config. Sets nonexistent values for the file locations and
# calls update() on remaining args.
#
#   my $config = TestConfig->new(
#      'core.engine'      => 'sqlite',
#      'add.all'          => 1,
#      'deploy.variables' => { _prefix => 'test_', user => 'bob' }
#      'foo.bar'          => [qw(one two three)],
#  );
sub new {
    my $self = shift->SUPER::new;
    $self->{test_local_file}  = 'nonexistent.local';
    $self->{test_user_file}   = 'nonexistent.user';
    $self->{test_system_file} = 'nonexistent.system';
    $self->update(@_);
    return $self;
}

# Pass in key/value pairs to set the data. Does not clear existing data. Keys
# should be "$section.$name". Values can be scalars, arrays, or hashes.
# Scalars are simply set as-is, unless the value is `undef`, in which case the
# key is deleted. Arrays are set as multiple values for the key. Hashes have
# each of their keys appended as "$section.$name.$key", with the values
# assigned as-is. Existing keys will be replaced with the new values.
#
#   my $config->update(
#      'core.engine'      => 'sqlite',
#      'add.all'          => 1,
#      'deploy.variables' => { _prefix => 'test_', user => 'bob' }
#      'foo.bar'          => [qw(one two three)],
#  );
sub update {
    my $self = shift;
    my %p = @_ or return;
    $self->data({}) unless $self->is_loaded;
    # Set a unique origin to be sure to override any previous values for each key.
    my @args = (origin => ('update_' . ++$self->{__update}));

    while (my ($k, $v) = each %p) {
        my $ref = ref $v;
        if ($ref eq '') {
            if (defined $v) {
                $k =~ s/[.]([^.]+)$//;
                $self->define(@args, section => $k, name => $1, value => $v);
            } else {
                $self->set_multiple( $k, 0 ) if $self->is_multiple( $k );
                $k = lc $k;
                delete $_->{$k} for ($self->origins, $self->data, $self->casing);
            }
        } elsif ($ref eq 'HASH') {
            $self->define(@args, section => $k, name => $_, value => $v->{$_} )
                for keys %{ $v };
        } elsif ($ref eq 'ARRAY') {
            $k =~ s/[.]([^.]+)$//;
            $self->define(@args, section => $k, name => $1, value => $_)
                for @{ $v };
        } else {
            require Carp;
            Carp::confess("Cannot set config value of type $ref");
        }
    }
}

# Like update(), but replaces all existing data with new data.
sub replace {
    my $self = shift;
    $self->data({});
    $self->multiple({});
    $self->origins({});
    $self->casing({});
    $self->config_files([]);
    $self->update(@_);
}

# Creates and returns a new TestConfig, which inherits from
# App::Sqitch::Config. Parameters specify files to load using the keys "local",
# "user", and "system". Any file not specified will be set to a nonexistent
# value. Once the files are set, the data is loaded from the files and the
# TestObject returned.
#
#   my $config = TestObject->from(
#      local  => 'test.conf',
#      user   => 'user.conf',
#      system => 'system.conf',
#   );
sub from {
    my ($class, %p) = @_;
    my $self = shift->SUPER::new;
    for my $level (qw(local user system)) {
        $self->{"test_${level}_file"} = $p{$level} || "nonexistent.$level";
    }
    $self->load;
    return $self;
}

# Creates and returns a Test::MockModule object that can be used to mock
# methods on the TestConfig class. Pass pairs of parameters to be passed on to
# the mock() method of the Test::MockModule object before returning.
#
# my $sysdir = dir 'nonexistent';
# my $usrdir = dir 'nonexistent';
# my $mock = TestConfig->mock(
#     system_dir => sub { $sysdir },
#     user_dir   => sub { $usrdir },
# );
sub mock {
    my $class = shift;
    require Test::MockModule;
    my $mocker = Test::MockModule->new($class);
    $mocker->mock(shift, shift) while @_;
    return $mocker;
}

# Returns the test local file.
sub local_file  { file $_[0]->{test_local_file}  }

# Returns the test user file.
sub user_file   { file $_[0]->{test_user_file}   }

# Returns the test system file.
sub system_file { file $_[0]->{test_system_file} }

# Overrides the parent implementation to load only the local file, to avoid
# inadvertent loading of configuration files in parent directories. Unlikely
# to be called directly by tests.
sub load_dirs   {
    my $self = shift;
    # Exclude files in parent directories.
    $self->load_file($self->local_file);
}

# Parses the specified configuration file and returns a hash reference. May be
# called as either a class or instance method; in neither case is the data
# stored anywhere other than the returned hash reference.
sub data_from {
    my $conf = shift->SUPER::new;
    $conf->load_file(shift);
    $conf->data;
}

1;
