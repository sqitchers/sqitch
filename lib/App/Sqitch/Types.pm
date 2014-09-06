package App::Sqitch::Types;

use 5.010;
use strict;
use warnings;
use utf8;
use Type::Library 0.040 -base, -declare => qw(
    Sqitch
    UserName
    UserEmail
    ConfigBool
    Plan
    Change
    ChangeList
    LineList
    Tag
    Depend
    DateTime
    URI
    URIDB
    File
    Dir
    Config
    DBH
);
use Type::Utils -all;
use Types::Standard -types;
use Locale::TextDomain 1.20 qw(App-Sqitch);
use App::Sqitch::X qw(hurl);
use App::Sqitch::Config;
use Scalar::Util qw(blessed);
use List::Util qw(first);

# Inherit standar types.
BEGIN { extends "Types::Standard" };

class_type Sqitch,     { class => 'App::Sqitch'                     };
class_type Plan,       { class => 'App::Sqitch::Plan'               };
class_type Change,     { class => 'App::Sqitch::Plan::Change'       };
class_type ChangeList, { class => 'App::Sqitch::Plan::ChangeList'   };
class_type LineList,   { class => 'App::Sqitch::Plan::LineList'     };
class_type Tag,        { class => 'App::Sqitch::Plan::Tag'          };
class_type Depend,     { class => 'App::Sqitch::Plan::Depend'       };
class_type DateTime,   { class => 'App::Sqitch::DateTime'           };
class_type URIDB,      { class => 'URI::db'                         };
class_type Config      { class => 'App::Sqitch::Config'             };
class_type File        { class => 'Path::Class::File'               };
class_type Dir         { class => 'Path::Class::Dir'                };
class_type DBH         { class => 'DBI::db'                         };

subtype UserName, as Str, where {
    hurl user => __ 'User name may not contain "<" or start with "["'
        if /^[[]/ || /</;
    1;
};

subtype UserEmail, as Str, where {
    hurl user => __ 'User email may not contain ">"' if />/;
    1;
};

# URI can be URI or URI::Nested.
declare name => URI, constraint => sub {
    my $o = $_;
    return blessed $o && first { $o->isa($_)} qw(URI URI::Nested URI::WithBase)
};

subtype ConfigBool, as Bool;
coerce ConfigBool, from Maybe[Value], via {
    my $bool = eval { App::Sqitch::Config->cast( value => $_, as => 'bool' ) };
    hurl user => __x('Unknown value ({val}) for boolean config option', val => $_)
        if $@;
    $bool;
};

1;
__END__

=head1 Name

App::Sqitch::Types - Definition of attribute data types

=head1 Synopsis

  use App::Sqitch::Types qw(Bool);

=head1 Description

This module defines data types use in Sqitch object attributes. Supported types
are:

=over

=item C<Sqitch>

An L<App::Sqitch> object.

=item C<UserName>

A Sqitch user name.

=item C<UserEmail>

A Sqitch user email address.

=item C<ConfigBool>

A value that can be converted to a boolean value suitable for storage in
Sqitch configuration files.

=item C<Plan>

A L<Sqitch::App::Plan> object.

=item C<Change>

A L<Sqitch::App::Plan::Change> object.

=item C<ChangeList>

A L<Sqitch::App::Plan::ChangeList> object.

=item C<LineList>

A L<Sqitch::App::Plan::LineList> object.

=item C<Tag>

A L<Sqitch::App::Plan::Tag> object.

=item C<Depend>

A L<Sqitch::App::Plan::Depend> object.

=item C<DateTime>

A L<Sqitch::App::DateTime> object.

=item C<URI>

A L<URI> object.

=item C<URIDB>

A L<URI::db> object.

=item C<File>

A C<Class::Path::File> object.

=item C<Dir>

A C<Class::Path::Dir> object.

=item C<Config>

A L<Sqitch::App::Config> object.

=item C<DBH>

A L<DBI> database handle.

=back

=head1 Author

David E. Wheeler <david@justatheory.com>

=head1 License

Copyright (c) 2012-2014 iovation Inc.

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
