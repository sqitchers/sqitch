App/Sqitch version v1.4.1
=========================

| Release           | Coverage          | Database                              ||
|-------------------|-------------------|-------------------|--------------------|
| [![CPAN]][📚]     | [![OSes]][💿]     | [![Exasol]][☀️]    | [![Oracle]][🔮]    |
| [![Docker]][🐳]   | [![Perl]][🧅]     | [![Firebird]][🔥] | [![Snowflake]][❄️]  |
| [![Homebrew]][🍺] | [![Coverage]][📈] | [![MySQL]][🐬]    | [![SQLite]][💡]    |
| [![Debian]][🍥]   |                   | [![Postgres]][🐘] | [![Vertica]][🔺]   |
|                   |                   | [![Yugabyte]][💫] | [![Cockroach]][🪳] |

[Sqitch] is a database change management application. It currently supports:

*   [PostgreSQL] 8.4+
*   [YugabyteDB] 2.6+
*   [CockroachDB] 21+
*   [SQLite][lite] 3.8.6+
*   [MySQL][my] 5.1+
*   [MariaDB] 10.0+
*   [Oracle][orcl] 10g+,
*   [Firebird][bird] 2.0+
*   [Vertica][vert] 7.2+
*   [Exasol][exa] 6.0+
*   [Snowflake][flake]

What makes it different from your typical migration approaches? A few things:

*   No opinions

    Sqitch is not tied to any framework, ORM, or platform. Rather, it is a
    standalone change management system with no opinions about your database
    engine, application framework, or development environment.

*   Native scripting

    Changes are implemented as scripts native to your selected database engine.
    Writing a [PostgreSQL] application? Write SQL scripts for [`psql`]. Writing
    an [Oracle][orcl]-backed app? Write SQL scripts for [SQL\*Plus].

*   Dependency resolution

    Database changes may declare dependencies on other changes -- even on
    changes from other Sqitch projects. This ensures proper order of
    execution, even when you've committed changes to your VCS out-of-order.

*   Deployment integrity

    Sqitch manages changes and dependencies via a plan file, employing a
    [Merkle tree] pattern similar to [Git][gitmerkle] and [Blockchain] to ensure
    deployment integrity. As such, there is no need to number your changes,
    although you can if you want. Sqitch doesn't much care how you name your
    changes.

*   Iterative Development

    Up until you [tag] and [release] your project, you can modify your change
    deployment scripts as often as you like. They're not locked in just because
    they've been committed to your VCS. This allows you to take an iterative or
    test-driven approach to developing your database schema.

Want to learn more? The best place to start is in the tutorials:

*   [Introduction to Sqitch on PostgreSQL, YugabyteDB, and CockroachDB](lib/sqitchtutorial.pod)
*   [Introduction to Sqitch on SQLite](lib/sqitchtutorial-sqlite.pod)
*   [Introduction to Sqitch on Oracle](lib/sqitchtutorial-oracle.pod)
*   [Introduction to Sqitch on MySQL](lib/sqitchtutorial-mysql.pod)
*   [Introduction to Sqitch on Firebird](lib/sqitchtutorial-firebird.pod)
*   [Introduction to Sqitch on Vertica](lib/sqitchtutorial-vertica.pod)
*   [Introduction to Sqitch on Exasol](lib/sqitchtutorial-exasol.pod)
*   [Introduction to Sqitch on Snowflake](lib/sqitchtutorial-snowflake.pod)

There have also been a number of presentations on Sqitch:

* [PDX.pm Presentation]: Slides from "Sane Database Management with Sqitch",
  presented to the Portland Perl Mongers in January, 2013.

* [PDXPUG Presentation]: Movie of "Sane Database Management with Sqitch",
  presented to the Portland PostgreSQL Users Group in September, 2012.

* [Agile Database Development]: Slides from a three-hour tutorial session on
  using [Git], test-driven development with [pgTAP], and change management with
  Sqitch, updated in January, 2014.

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
no modules that are included in the core Perl distribution are included. To
require that dual-life modules also be bundled, pass `--dual_life 1`:

    ./Build bundle --install_base sqitch_bundle --dual_life 1

To include support for a feature in the bundle, pass the `--with` option
naming the feature:

    ./Build bundle --install_base sqitch_bundle --with postgres --with sqlite

The feature names generally correspond to the supported engines. The currently
supported features are:

*   `--with postgres`:  Support for managing Postgres, Yugabyte, and Cockroach databases
*   `--with sqlite`:    Support for managing SQLite databases
*   `--with mysql`:     Support for managing MySQL databases
*   `--with firebird`:  Support for managing Firebird databases
*   `--with oracle`:    Support for managing Oracle databases
*   `--with vertica`:   Support for managing Vertica databases
*   `--with exasol`:    Support for managing Exasol databases
*   `--with snowflake`: Support for managing Snowflake databases
*   `--with odbc`:      Include the ODBC driver

To build from a Git clone, first install [Dist::Zilla], then use it to install
Sqitch and all dependencies:

    cpanm Dist::Zilla
    dzil authordeps --missing | cpanm
    dzil listdeps --missing | cpanm
    dzil install

To run Sqitch directly from the Git clone, execute `t/sqitch`.

To install Sqitch on a specific platform, including Debian- and RedHat-derived
Linux distributions and Windows, see the [Installation documentation].

License
-------

Copyright (c) 2012-2024 iovation Inc., David E. Wheeler

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

  [CPAN]:      https://img.shields.io/cpan/v/App-Sqitch?label=%F0%9F%93%9A%20CPAN
  [📚]:        https://metacpan.org/dist/App-Sqitch "Latest version on CPAN"
  [OSes]:      https://github.com/sqitchers/sqitch/actions/workflows/os.yml/badge.svg
  [💿]:        https://github.com/sqitchers/sqitch/actions/workflows/os.yml "Tested on Linux, macOS, and Windows"
  [Exasol]:    https://github.com/sqitchers/sqitch/actions/workflows/exasol.yml/badge.svg
  [☀️]:         https://github.com/sqitchers/sqitch/actions/workflows/exasol.yml "Tested with Exasol 7.0–7.1"
  [Oracle]:    https://github.com/sqitchers/sqitch/actions/workflows/oracle.yml/badge.svg
  [🔮]:        https://github.com/sqitchers/sqitch/actions/workflows/oracle.yml "Tested with Oracle 11, 18, and 21"
  [Docker]:    https://img.shields.io/docker/v/sqitch/sqitch?label=%F0%9F%90%B3%20Docker&sort=semver
  [🐳]:        https://hub.docker.com/r/sqitch/sqitch "Latest version on Docker Hub"
  [Perl]:      https://github.com/sqitchers/sqitch/actions/workflows/perl.yml/badge.svg
  [🧅]:        https://github.com/sqitchers/sqitch/actions/workflows/perl.yml "Tested with Perl 5.12–5.38"
  [Firebird]:  https://github.com/sqitchers/sqitch/actions/workflows/firebird.yml/badge.svg
  [🔥]:        https://github.com/sqitchers/sqitch/actions/workflows/firebird.yml "Tested with Firebird 2.5, 3, and 4"
  [Snowflake]: https://github.com/sqitchers/sqitch/actions/workflows/snowflake.yml/badge.svg
  [❄️]:         https://github.com/sqitchers/sqitch/actions/workflows/snowflake.yml "Tested with Snowflake"
  [Homebrew]:  https://img.shields.io/github/v/tag/sqitchers/homebrew-sqitch?label=%F0%9F%8D%BA%20Homebrew&sort=semver
  [🍺]:        https://github.com/sqitchers/homebrew-sqitch#readme "Latest Homebrew Tap version"
  [Coverage]:  https://img.shields.io/coveralls/github/sqitchers/sqitch?label=%F0%9F%93%88%20Coverage
  [📈]:        https://coveralls.io/r/sqitchers/sqitch "Test Coverage"
  [MySQL]:     https://github.com/sqitchers/sqitch/actions/workflows/mysql.yml/badge.svg
  [🐬]:        https://github.com/sqitchers/sqitch/actions/workflows/mysql.yml "Tested with MySQL 5.5–8 and MariaDB 10.0–11.0"
  [SQLite]:    https://github.com/sqitchers/sqitch/actions/workflows/sqlite.yml/badge.svg
  [💡]:        https://github.com/sqitchers/sqitch/actions/workflows/sqlite.yml "Tested with SQLite 3.8–3.42"
  [Debian]:    https://img.shields.io/debian/v/sqitch?label=%F0%9F%8D%A5%20Debian
  [🍥]:        https://packages.debian.org/stable/sqitch "Latest version on Debian"
  [Postgres]:  https://github.com/sqitchers/sqitch/actions/workflows/pg.yml/badge.svg
  [🐘]:        https://github.com/sqitchers/sqitch/actions/workflows/pg.yml "Tested with PostgreSQL 8.4–16"
  [Yugabyte]:  https://github.com/sqitchers/sqitch/actions/workflows/yugabyte.yml/badge.svg
  [💫]:        https://github.com/sqitchers/sqitch/actions/workflows/yugabyte.yml "Tested with YugabyteDB 2.6–2.19"
  [Vertica]:   https://github.com/sqitchers/sqitch/actions/workflows/vertica.yml/badge.svg
  [🔺]:        https://github.com/sqitchers/sqitch/actions/workflows/vertica.yml "Tested with Vertica 7.2–12.0"
[Cockroach]: https://github.com/sqitchers/sqitch/actions/workflows/cockroach.yml/badge.svg
  [🪳]:        https://github.com/sqitchers/sqitch/actions/workflows/cockroach.yml "Tested with CockroachDB v21-23"

  [Sqitch]: https://sqitch.org/
  [PostgreSQL]: https://postgresql.org/
  [YugabyteDB]: https://www.yugabyte.com/yugabytedb/
  [CockroachDB]: https://www.cockroachlabs.com/product/
  [lite]: https://sqlite.org/
  [my]: https://dev.mysql.com/
  [MariaDB]: https://mariadb.org
  [`psql`]: https://www.postgresql.org/docs/current/static/app-psql.html
  [orcl]: https://www.oracle.com/database/
  [bird]: https://www.firebirdsql.org/
  [vert]: https://www.vertica.com/
  [exa]: https://www.exasol.com/
  [flake]: https://www.snowflake.net/
  [SQL\*Plus]: https://www.orafaq.com/wiki/SQL*Plus
  [Merkle tree]: https://en.wikipedia.org/wiki/Merkle_tree "Wikipedia: “Merkle tree”"
  [gitmerkle]: https://stackoverflow.com/a/18589734/
    "Stack Overflow: “What is the mathematical structure that represents a Git repo”"
  [Blockchain]: https://medium.com/byzantine-studio/blockchain-fundamentals-what-is-a-merkle-tree-d44c529391d7
    "Medium: “Blockchain Fundamentals #1: What is a Merkle Tree?”"
  [tag]: https://sqitch.org/docs/manual/sqitch-tag/
  [release]: https://sqitch.org/docs/manual/sqitch-tag/
  [PDX.pm Presentation]: https://speakerdeck.com/theory/sane-database-change-management-with-sqitch
  [PDXPUG Presentation]: https://vimeo.com/50104469
  [Agile Database Development]: https://speakerdeck.com/theory/agile-database-development-2ed
  [Git]: https://git-scm.org
  [pgTAP]: https://pgtap.org
  [Dist::Zilla]: https://metacpan.org/module/Dist::Zilla
  [Installation documentation]: https://sqitch.org/download/
