package App::Sqitch::Plan::Tag;

use 5.010;
use utf8;
use namespace::autoclean;
use Moo;
use App::Sqitch::Types qw(Str Change UserEmail DateTime);
use Encode;

extends 'App::Sqitch::Plan::Line';

our $VERSION = '0.9997';

sub format_name {
    '@' . shift->name;
}

has info => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;

        return join "\n", (
            'project ' . $self->project,
            ( $self->uri ? ( 'uri ' . $self->uri->canonical ) : () ),
            'tag '     . $self->format_name,
            'change '  . $self->change->id,
            'planner ' . $self->format_planner,
            'date '    . $self->timestamp->as_string,
            ( $self->note ? ('', $self->note) : ()),
        );
    }
);

has id => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $content = encode_utf8 shift->info;
        require Digest::SHA;
        return Digest::SHA->new(1)->add(
            'tag ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

has old_info => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $self = shift;
        my $plan = $self->plan;

        return join "\n", (
            'project ' . $self->project,
            ( $self->uri ? ( 'uri ' . $self->uri->canonical ) : () ),
            'tag '     . $self->format_name,
            'change '  . $self->change->id,
            'planner ' . $self->format_planner,
            'date '    . $self->timestamp->as_string,
        );
    }
);

has old_id => (
    is       => 'ro',
    isa      => Str,
    lazy     => 1,
    default  => sub {
        my $content = encode_utf8 shift->old_info;
        require Digest::SHA;
        return Digest::SHA->new(1)->add(
            'tag ' . length($content) . "\0" . $content
        )->hexdigest;
    }
);

has change => (
    is       => 'ro',
    isa      => Change,
    weak_ref => 1,
    required => 1,
);

has timestamp => (
    is       => 'ro',
    isa      => DateTime,
    default  => sub { require App::Sqitch::DateTime && App::Sqitch::DateTime->now },
);

has planner_name => (
    is       => 'ro',
    isa      => Str,
    default  => sub { shift->sqitch->user_name },
);

has planner_email => (
    is       => 'ro',
    isa      => UserEmail,
    default  => sub { shift->sqitch->user_email },
);

sub format_planner {
    my $self = shift;
    return join ' ', $self->planner_name, '<' . $self->planner_email . '>';
}

sub format_content {
    my $self = shift;
    return join ' ',
        $self->SUPER::format_content,
        $self->timestamp->as_string,
        $self->format_planner;
}

1;

__END__

=head1 Name

App::Sqitch::Plan::Tag - Sqitch deployment plan tag

=head1 Synopsis

  my $plan = App::Sqitch::Plan->new( sqitch => $sqitch );
  for my $line ($plan->lines) {
      say $line->as_string;
  }

=head1 Description

A App::Sqitch::Plan::Tag represents a tag as parsed from a plan file. In
addition to the interface inherited from L<App::Sqitch::Plan::Line>, it offers
interfaces fetching and formatting timestamp and planner information.

=head1 Interface

See L<App::Sqitch::Plan::Line> for the basics.

=head2 Accessors

=head3 C<change>

Returns the L<App::Sqitch::Plan::Change> object with which the tag is
associated.

=head3 C<timestamp>

Returns the an L<App::Sqitch::DateTime> object representing the time at which
the tag was added to the plan.

=head3 C<planner_name>

Returns the name of the user who added the tag to the plan.

=head3 C<planner_email>

Returns the email address of the user who added the tag to the plan.

=head3 C<info>

Information about the tag, returned as a string. Includes the tag ID, the ID
of the associated change, the name and email address of the user who added the
tag to the plan, and the timestamp for when the tag was added to the plan.

=head3 C<id>

A SHA1 hash of the data returned by C<info()>, which can be used as a
globally-unique identifier for the tag.

=head2 Instance Methods

=head3 C<format_planner>

  my $planner = $tag->format_planner;

Returns a string formatted with the name and email address of the user who
added the tag to the plan.


=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2017 iovation Inc.

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
