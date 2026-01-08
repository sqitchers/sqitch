package App::Sqitch::Command::grep;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X     qw(hurl);
use Moo;
use App::Sqitch::Target;
use App::Sqitch::Types qw(Enum Target Bool);
use File::Find::Rule;
use File::Basename        qw(fileparse);
use File::Spec::Functions qw(catdir splitdir);
use namespace::autoclean;

extends 'App::Sqitch::Command';

# VERSION

has [qw/type t/] => (
    is  => 'ro',
    isa => Enum [qw( deploy verify revert )],
);

has [qw/insensitive i/] => (
    is  => 'ro',
    isa => Bool,
);

has [qw/list l/] => (
    is  => 'ro',
    isa => Bool,
);

has [qw/regex e/] => (
    is  => 'ro',
    isa => Bool,
);

has target => (
    is      => 'ro',
    isa     => Target,
    lazy    => 1,
    default => sub { return App::Sqitch::Target->new( sqitch => shift->sqitch ) },
);

sub options {
    my $self = shift;
    return $self->SUPER::options(@_), qw(
      t|type=s
      i|insensitive
      l|list
      e|regex
    );
}

sub execute {
    my ( $self, @args ) = @_;
    unless (@args) {
        hurl grep => __x( 'No search terms supplied for {command}', command => 'sqitch grep' );
    }
    my $target = $self->target;

    # get our change names indexed by the order they appear in the plan
    my $i        = 0;
    my %order_by = map { $_->name => $i++ } grep { $_->isa('App::Sqitch::Plan::Change') } $target->plan->lines;

    my ( $deploy_dir, $verify_dir, $revert_dir ) = map { $target->$_ } qw/deploy_dir verify_dir revert_dir/;
    my $type = $self->type // $self->t // '';
    my $search_dir
      = 'deploy' eq $type ? $deploy_dir
      : 'verify' eq $type ? $verify_dir
      : 'revert' eq $type ? $revert_dir
      :                     $target->top_dir;
    my @files = $self->get_files( $search_dir, @args );

    my $extension = $target->extension;
    my %name_for;

    # sort files by the order in which the names show up in the plan
    my $by_plan = sub {
        return 0 if $a eq $b;    # shouldn't happen?

        # if a and b are not exact matches, always return in the order of
        # deploy, verify, revert
        return -1 if $a =~ /^$deploy_dir/ and $b !~ /^$deploy_dir/;
        return -1 if $a =~ /^$verify_dir/ and $b =~ /^$revert_dir/;
        return 1  if $b =~ /^$deploy_dir/ and $a !~ /^$deploy_dir/;
        return 1  if $b =~ /^$verify_dir/ and $a =~ /^$revert_dir/;

        # ok, we got to here. Their top-level directory is the same, so let's
        # figure out the sort order
        my $dir;
        foreach ( $deploy_dir, $verify_dir, $revert_dir ) {
            $dir = $_ if $a =~ /^$_/;
        }
        unless ($dir) {

            # we have no idea what this file is (probably junk), so sort it
            # last
            return 1;
        }

        my @remove = splitdir($dir);
        foreach my $this_file ( $a, $b ) {

            # this takes some time, so cache these puppies
            unless ( exists $name_for{$this_file} ) {
                my ( $name, $path, undef ) = fileparse( $this_file, $extension );
                my @path       = splitdir( catdir( $path, $name ) );
                my $last_index = -1 * ( @path - scalar @remove );
                my $this_name  = catdir( splice @path, $last_index );    # strip leading dir
                $this_name =~ s/\.$//;                                   # remove trailing dot
                $name_for{$this_file} = $this_name;
            }
        }

        # all of these *should* exist, but sometimes sqitch directories can have
        # "old" sqitch files which didn't make it into the plan.
        # Or, um, there's a bug in my code.
        return ( $order_by{ $name_for{$a} } // $i ) <=> ( $order_by{ $name_for{$b} } // $i );
    };
    @files = sort $by_plan @files;

    if ( $self->list || $self->l ) {
        say for @files;
    }
    else {
        $self->show_matches( \@files, @args );
    }
}

sub show_matches {
    my ( $self, $files, @args ) = @_;
    my $pattern = join ' ', @args;

    # Escape regex special chars unless --regex is specified
    $pattern = quotemeta($pattern) unless ( $self->regex || $self->e );

    my $regex = ( $self->insensitive || $self->i ) ? qr/$pattern/i : qr/$pattern/;
    FILE: foreach my $file (@$files) {
        if ( open my $fh, '<:utf8_strict', $file ) {
            while ( my $line = <$fh> ) {
                if ( $line =~ /$regex/ ) {
                    printf "%s:%d: %s" => $file, $., $line;
                }
            }
            close $fh;
        }
        else {
            $self->warn(
                __x('Could not search "{file}": {error}',
                    file  => $file,
                    error => $!,
                )
            );
        }
    }
}

sub get_files {
    my ( $self, $search_dir, @args ) = @_;
    my $target  = $self->target;
    my $pattern = join ' ', @args;

    # Escape regex special chars unless --regex is specified
    $pattern = quotemeta($pattern) unless ( $self->regex || $self->e );

    my $extension = $target->extension;
    my $rule      = File::Find::Rule->file->name("*.$extension");
    $rule->grep( ( $self->insensitive || $self->i ) ? qr/$pattern/i : qr/$pattern/ );
    return $rule->in($search_dir);
}

1;

__END__

=head1 Name

App::Sqitch::Command::grep - Search sqitch changes

=head1 Synopsis

  my $cmd = App::Sqitch::Command::grep->new(%params);
  $cmd->execute;

=head1 Description

A lightweight version of C<grep>, this command allows you to search for files
in your C<sqitch> directories, but it returns them in the order they were
defined in your plan (with deploy, verify, and revert directories being sorted
in that order).

By default, searches for literal strings. Use C<--regex> for pattern matching.

This command provides an advantage over regular grep by sorting results
according to the plan, making it easier to find specific changes in
chronological order.

=head1 Interface

=head2 Attributes

=head3 C<type>

=head3 C<t>

The type of change scripts to search (deploy, verify, or revert). Both C<type>
and C<t> are aliases for the same attribute.

=head3 C<insensitive>

=head3 C<i>

Boolean indicating whether to perform case-insensitive search. Both
C<insensitive> and C<i> are aliases for the same attribute.

=head3 C<list>

=head3 C<l>

Boolean indicating whether to list only filenames instead of matching lines.
Both C<list> and C<l> are aliases for the same attribute.

=head3 C<regex>

=head3 C<e>

Boolean indicating whether to treat search terms as regular expressions. Both
C<regex> and C<e> are aliases for the same attribute.

=head2 Instance Methods

=head3 C<execute>

  $grep->execute(@search_terms);

Executes the grep command with the provided search terms.

=head3 C<get_files>

  my @files = $grep->get_files($search_dir, @search_terms);

Returns a list of files in the specified directory that match the search terms.

=head3 C<show_matches>

  $grep->show_matches(\@files, @search_terms);

Displays matching lines from the specified files with filename and line number.

=head1 Command Line Options

All options are optional

    --type -t         deploy/verify/revert   Which sqitch change type to search
    --list -l                                Only show filenames
    --insensitive -i                         Case-insensitive search
    --regex -e                               Treat search as regex pattern (default: literal)

Example: search all C<deploy> changes for C<ALTER TABLE>, case-insensitively:

    sqitch grep --type deploy -i ALTER TABLE

Example: search for a literal string with special characters:

    sqitch grep "price.$"

Example: search using a regex pattern:

    sqitch grep --regex "CREATE\s+(TABLE|INDEX)"

=head1 See Also

=over

=item L<sqitch-grep>

Documentation for the C<grep> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2025 David E. Wheeler, 2012-2021 iovation Inc.

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
