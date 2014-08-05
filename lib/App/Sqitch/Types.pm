package App::Sqitch::Types;

use 5.010;
use strict;
use warnings;
use utf8;
use Type::Library -base, -declare => qw(
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
    DBI
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
class_type DBI         { class => 'DBI::db'                         };

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
