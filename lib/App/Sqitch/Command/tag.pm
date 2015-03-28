package App::Sqitch::Command::tag;

use 5.010;
use strict;
use warnings;
use utf8;
use Moo;
use App::Sqitch::X qw(hurl);
use Types::Standard qw(Str ArrayRef Maybe Bool);
use Locale::TextDomain qw(App-Sqitch);
use namespace::autoclean;

extends 'App::Sqitch::Command';

our $VERSION = '0.999_1';

has tag_name => (
    is  => 'ro',
    isa => Maybe[Str],
);

has change_name => (
    is  => 'ro',
    isa => Maybe[Str],
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

sub options {
    return qw(
        tag-name|tag|t=s
        change-name|change|c=s
        all|a!
        note|n|m=s@
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;
    # Just keep options.
    return $opt;
}

sub execute {
    my $self   = shift;
    my ($name, $change, $targets) = $self->parse_target_args(
        names => [$self->tag_name, $self->change_name],
        all   => $self->all,
        args  => \@_
    );

    if (defined $name) {
        my $note = join "\n\n" => @{ $self->note };
        my (%seen, @plans, @tags);
        for my $target (@{ $targets }) {
            next if $seen{$target->plan_file}++;
            my $plan = $target->plan;
            push @tags => $plan->tag(
                name   => $name,
                change => $change,
                note   => $note,
            );
            push @plans => $plan;
        }

        # Make sure we have a note.
        $note = $tags[0]->request_note(for => __ 'tag');

        # We good, write the plan files back out.
        for my $plan (@plans) {
            my $tag = shift @tags;
            $tag->note($note);
            $plan->write_to( $plan->file );
            $self->info(__x(
                'Tagged "{change}" with {tag} in {file}',
                change => $tag->change->format_name,
                tag    => $tag->format_name,
                file   => $plan->file,
            ));
        }
    } else {
        # Show unique tags.
        my %seen;
        for my $target (@{ $targets }) {
            my $plan = $target->plan;
            for my $tag ($plan->tags) {
                my $name = $tag->format_name;
                $self->info($name) unless $seen{$name}++;
            }
        }
    }

    return $self;
}

1;

__END__

=head1 Name

App::Sqitch::Command::tag - Add or list tags in Sqitch plans

=head1 Synopsis

  my $cmd = App::Sqitch::Command::tag->new(%params);
  $cmd->execute;

=head1 Description

Tags a Sqitch change. The tag will be added to the last change in the plan.

=head1 Interface

=head2 Attributes

=head3 C<tag_name>

The name of the tag to add.

=head3 C<change_name>

The name of the change to tag.

=head3 C<all>

Boolean indicating whether or not to run the command against all plans in the
project.

=head3 C<note>

Text of the tag note.

=head2 Instance Methods

=head3 C<execute>

  $tag->execute($command);

Executes the C<tag> command.

=head1 See Also

=over

=item L<sqitch-tag>

Documentation for the C<tag> command to the Sqitch command-line client.

=item L<sqitch>

The Sqitch command-line client.

=back

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
