package App::Sqitch::Command::show;

use 5.010;
use strict;
use warnings;
use utf8;
use Locale::TextDomain qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use List::Util qw(first);
use Mouse;
extends 'App::Sqitch::Command';

our $VERSION = '0.970';

sub execute {
    my ( $self, $type, $key ) = @_;
    $self->usage unless $type && $key;

    # Handle tags first.
    if ( $type eq 'tag' ) {
        my $is_id = $key =~ /^[0-9a-f]{40}/;
        my $change = $self->plan->get(
            $is_id ? $key : ($key =~ /^@/ ? '' : '@') . $key
        );

        my $tag = $change ? do {
            if ($is_id) {
                # It's a tag ID.
                first { $_->id eq $key } $change->tags;
            } else {
                # Tag name.
                (my $name = $key) =~ s/^[@]//;
                first { $_->name eq $name } $change->tags;
            }
        } : undef;
        hurl show => __x( 'Unknown tag "{tag}"', tag => $key )
            unless $tag;
        $self->emit( $tag->info ) if $tag;
        return $self;
    }

    # Make sure we recognize the type.
    hurl show => __x(
        'Unknown object type "{type}',
        type => $type,
    ) unless first { $type eq $_ } qw(change deploy revert verify);

    # Make sure we have a change object.
    my $change = $self->plan->get($key) or  hurl show => __x(
        'Unknown change "{change}"',
        change => $key
    );

    if ($type eq 'change') {
        # Just show its info.
        $self->emit( $change->info );
        return $self;
    }

    my $meth = $change->can("$type\_file");
    my $path = $change->$meth;
    hurl show => __x('File "{path}" does not exist', path => $path)
        unless -e $path;
    hurl show => __x('"{path}" is not a file', path => $path)
        if $path->is_dir;

    # Assume nothing about the encoding.
    binmode STDOUT, ':raw';
    $self->emit( $path->slurp(iomode => '<:raw') );
    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::show - Show Sqitch changes to a database

=head1 Synopsis

  my $cmd = App::Sqitch::Command::show->new(%params);
  $cmd->execute($type, $name);

=head1 Description

Shows the content of a Sqitch object.

If you want to know how to use the C<show> command, you probably want to be
reading C<sqitch-show>. But if you really want to know how the C<show> command
works, read on.

=head1 Interface

=head2 Class Methods

=head3 C<options>

  my @opts = App::Sqitch::Command::show->options;

Returns a list of L<Getopt::Long> option specifications for the command-line
options for the C<show> command.

=head2 Instance Methods

=head3 C<execute>

  $show->execute;

Executes the show command.

=head1 See Also

=over

=item L<sqitch-show>

Documentation for the C<show> command to the Sqitch command-line client.

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
