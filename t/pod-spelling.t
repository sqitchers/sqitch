#!/usr/bin/perl -w

use strict;
use Test::More;
eval "use Test::Spelling";
plan skip_all => "Test::Spelling required for testing POD spelling" if $@;

add_stopwords(<DATA>);
all_pod_files_spelling_ok();

__DATA__
iovation
noninfringement
RDBMS
RDBMSes
SQLite
sqitch
VCS
sublicense
subdirectories
EBNF
UTF
ftw
MySQL
ORM
blog
depesz
Flipr
GitHub
PostgreSQL's
sqitchtutorial
VCSes
Versioning
metadata
namespace
DDLs
SHA
untracked
yay
