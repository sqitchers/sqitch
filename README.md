App/Sqitch version 0.9998
=========================

[![CPAN version](https://badge.fury.io/pl/App-Sqitch.svg)](http://badge.fury.io/pl/App-Sqitch)
[![Build Status](https://travis-ci.org/theory/sqitch.svg)](https://travis-ci.org/theory/sqitch)
[![Coverage Status](https://coveralls.io/repos/theory/sqitch/badge.svg)](https://coveralls.io/r/theory/sqitch)

[Sqitch](http://sqitch.org/) is a database change management application. It
currently supports PostgreSQL 8.4+, SQLite 3.7.11+, MySQL 5.0+, Oracle 10g+,
Firebird 2.0+, Vertica 6.0+, Exasol 6.0+ and Snowflake.

What makes it different from your typical
[migration](http://guides.rubyonrails.org/migrations.html) approaches? A few
things:

*   No opinions

    Sqitch is not integrated with any framework, ORM, or platform. Rather, it
    is a standalone change management system with no opinions about your
    database engine, application framework, or your development environment.

*   Native scripting

    Changes are implemented as scripts native to your selected database
    engine. Writing a [PostgreSQL](http://postgresql.org/) application? Write
    SQL scripts for
    [`psql`](http://www.postgresql.org/docs/current/static/app-psql.html).
    Writing an [Oracle](http://www.oracle.com/us/products/database/)-backed app?
    Write SQL scripts for [SQL\*Plus](http://www.orafaq.com/wiki/SQL*Plus).

*   Dependency resolution

    Database changes may declare dependencies on other changes -- even on
    changes from other Sqitch projects. This ensures proper order of
    execution, even when you've committed changes to your VCS out-of-order.

*   No numbering

    Change deployment is managed by maintaining a plan file. As such, there is
    no need to number your changes, although you can if you want. Sqitch
    doesn't much care how you name your changes.

*   Iterative Development

    Up until you tag and release your project, you can modify your change
    deployment scripts as often as you like. They're not locked in just
    because they've been committed to your VCS. This allows you to take an
    iterative approach to developing your database schema. Or, better, you can
    do test-driven database development.

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
  Slides from a three-hour tutorial session on using [Git](http://git-scm.org),
  test-driven development with [pgTAP](http://pgtap.org), and change
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
`sqtich_bundle`, type:

    ./Build bundle --install_base sqitch_bundle

After which, Sqtich can be run from `./sqitch_bundle/bin/sqitch`.

To build from a Git clone, first install
[Dist::Zilla](https://metacpan.org/module/Dist::Zilla), then use it to install
Sqitch and its dependencies:

    cpan Dist::Zilla
    dzil install

To run Sqitch directly from the Git clone execute `t/sqitch`. If you're doing
development on Sqitch, you will need to install the authoring dependencies, as
well:

    dzil listdeps | xargs cpan

To install Sqitch on a specific platform, including Debian- and RedHat-derived
Linux distributions and Windows, see the
[Installation documentation](http://sqitch.org/#installation).

Licence
-------

Copyright © 2012-2018 iovation Inc.

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
