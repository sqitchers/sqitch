App/Sqitch version v1.1.1
=========================

[![CPAN version](https://badge.fury.io/pl/App-Sqitch.svg)](https://badge.fury.io/pl/App-Sqitch)
[![Build Status](https://travis-ci.com/sqitchers/sqitch.svg)](https://travis-ci.com/sqitchers/sqitch)
[![Coverage Status](https://coveralls.io/repos/sqitchers/sqitch/badge.svg)](https://coveralls.io/r/sqitchers/sqitch)

[Sqitch](https://sqitch.org/) is a database change management application. It
currently supports PostgreSQL 8.4+, SQLite 3.7.11+, MySQL 5.0+, Oracle 10g+,
Firebird 2.0+, Vertica 6.0+, Exasol 6.0+ and Snowflake.

What makes it different from your typical
[migration](https://guides.rubyonrails.org/migrations.html) approaches? A few
things:

*   No opinions

    Sqitch is not tied to any framework, ORM, or platform. Rather, it is a
    standalone change management system with no opinions about your database
    engine, application framework, or development environment.

*   Native scripting

    Changes are implemented as scripts native to your selected database
    engine. Writing a [PostgreSQL](https://postgresql.org/) application? Write
    SQL scripts for
    [`psql`](https://www.postgresql.org/docs/current/static/app-psql.html).
    Writing an [Oracle](https://www.oracle.com/database/)-backed app?
    Write SQL scripts for [SQL\*Plus](https://www.orafaq.com/wiki/SQL*Plus).

*   Dependency resolution

    Database changes may declare dependencies on other changes -- even on
    changes from other Sqitch projects. This ensures proper order of
    execution, even when you've committed changes to your VCS out-of-order.

*   Deployment integrity

    Sqitch manages changes and dependencies via a plan file, and employs a
    [Merkle tree](https://en.wikipedia.org/wiki/Merkle_tree "Wikipedia: “Merkle tree”")
    pattern similar to
    [Git](https://stackoverflow.com/a/18589734/ "Stack Overflow: “What is the mathematical structure that represents a Git repo”")
    and [Blockchain](https://medium.com/byzantine-studio/blockchain-fundamentals-what-is-a-merkle-tree-d44c529391d7 "Medium: “Blockchain Fundamentals #1: What is a Merkle Tree?”")
    to ensure deployment integrity.
    As such, there is no need to number your changes, although you can if you
    want. Sqitch doesn't much care how you name your changes.

*   Iterative Development

    Up until you [tag](https://sqitch.org/docs/manual/sqitch-tag/) and
    [release](https://sqitch.org/docs/manual/sqitch-tag/) your project, you
    can modify your change deployment scripts as often as you like. They're
    not locked in just because they've been committed to your VCS. This allows
    you to take an iterative approach to developing your database schema. Or,
    better, you can do test-driven database development.

Want to learn more? The best place to start is in the tutorials:

* [Introduction to Sqitch on PostgreSQL](lib/sqitchtutorial.pod)
* [Introduction to Sqitch on SQLite](lib/sqitchtutorial-sqlite.pod)
* [Introduction to Sqitch on Oracle](lib/sqitchtutorial-oracle.pod)
* [Introduction to Sqitch on MySQL](lib/sqitchtutorial-mysql.pod)
* [Introduction to Sqitch on Firebird](lib/sqitchtutorial-firebird.pod)
* [Introduction to Sqitch on Vertica](lib/sqitchtutorial-vertica.pod)
* [Introduction to Sqitch on Exasol](lib/sqitchtutorial-exasol.pod)
* [Introduction to Sqitch on Snowflake](lib/sqitchtutorial-snowflake.pod)

There have also been a number of presentations on Sqitch:

* [PDX.pm Presentation](https://speakerdeck.com/theory/sane-database-change-management-with-sqitch):
  Slides from "Sane Database Management with Sqitch", presented to the
  Portland Perl Mongers in January, 2013.

* [PDXPUG Presentation](https://vimeo.com/50104469): Movie of "Sane Database
  Management with Sqitch", presented to the Portland PostgreSQL Users Group in
  September, 2012.

* [Agile Database Development](https://speakerdeck.com/theory/agile-database-development-2ed):
  Slides from a three-hour tutorial session on using [Git](https://git-scm.org),
  test-driven development with [pgTAP](https://pgtap.org), and change
  management with Sqitch, updated in January, 2014.

Installation
------------

To install Sqitch from a distribution download, type the following:

    perl Build.PL
    ./Build installdeps
    ./Build
    ./Build test
    ./Build install

To install Sqitch and all of its dependencies into a single directory named
`sqitch_bundle`, install the Menlo CPAN client and build the bundle:

    cpanm Menlo::CLI::Compat
    ./Build bundle --install_base sqitch_bundle

After which, Sqitch can be run from `./sqitch_bundle/bin/sqitch`. By default,
no modules that are included in the core Perl distrituion are included. To
require that dual-life modules also be bundled, pass `--dual_life 1`:

    ./Build bundle --install_base sqitch_bundle --dual_life 1

To include support for a feature in the bundle, pass the `--with` option
naming the feature:

    ./Build bundle --install_base sqitch_bundle --with postgres --with sqlite

The feature names generally correspond to the supported engines. The currently
supported features are:

*   `--with postgres`:  Support for managing PostgreSQL databases
*   `--with sqlite`:    Support for managing SQLite databases
*   `--with mysql`:     Support for managing MySQL databases
*   `--with firebird`:  Support for managing Firebird databases
*   `--with oracle`:    Support for managing Oracle databases
*   `--with vertica`:   Support for managing Vertica databases
*   `--with exasol`:    Support for managing Exasol databases
*   `--with snowflake`: Support for managing Snowflake databases
*   `--with odbc`:      Include the ODBC driver

To build from a Git clone, first install
[Dist::Zilla](https://metacpan.org/module/Dist::Zilla), then use it to install
Sqitch and all dependencies:

    cpanm Dist::Zilla
    dzil authordeps --missing | cpanm
    dzil listdeps --missing | cpanm
    dzil install

To run Sqitch directly from the Git clone, execute `t/sqitch`.

To install Sqitch on a specific platform, including Debian- and RedHat-derived
Linux distributions and Windows, see the
[Installation documentation](https://sqitch.org/#installation).

License
-------

Copyright © 2012-2021 iovation Inc.

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
