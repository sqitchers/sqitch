App/Sqitch version 0.970
========================

[Sqitch](http://sqitch.org/) is a database change management application. It
currently supports PostgreSQL 8.4 and higher, SQLite 3, and Oracle 10g and
higher.

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

    Up until you tag and release your application, you can modify your change
    deployment scripts as often as you like. They're not locked in just
    because they've been committed to your VCS. This allows you to take an
    iterative approach to developing your database schema. Or, better, you can
    do test-driven database development.

*   Reduced Duplication

    If you're using a VCS to track your changes, you don't have to duplicate
    xentire change scripts for simple changes. As long as the changes are
    [idempotent](http://en.wikipedia.org/wiki/Idempotence), you can change
    your code directly, and Sqitch will know it needs to be updated.

Want to learn more? The best place to start is in the tutorials:

* [Introduction to Sqitch on PostgreSQL](lib/sqitchtutorial.pod)
* [Introduction to Sqitch on SQLite](lib/sqitchtutorial-sqlite.pod)

Installation
------------

To install this module, type the following:

    perl Build.PL
    ./Build installdeps
    ./Build
    ./Build test
    ./Build install

Licence
-------

Copyright © 2012-2013 iovation Inc.

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
