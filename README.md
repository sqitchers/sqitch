App/Sqitch version 0.10
=======================

This application, `sqitch`, will provide a simple yet robust interface for SQL
change management. The philosophy and functionality is covered over a series
of blog posts published in January, 2012:

* [Simple SQL Change Management](http://justatheory.com/computers/databases/simple-sql-change-management.html)
* [VCS-Enabled SQL Change Management](http://justatheory.com/computers/databases/vcs-sql-change-management.html)
* [SQL Change Management Sans Duplication](http://justatheory.com/computers/databases/sql-change-management-sans-redundancy.html)

Installation
------------

To install this module, type the following:

    perl Build.PL
    ./Build
    ./Build test
    ./Build install

Or, if you don't have Module::Build installed, type the following:

    perl Makefile.PL
    make
    make test
    make install

Dependencies
------------

App::Sqitch requires the following modules:


### Git Notes ###

* Get a list of all commits and tags:

        git log --format='[%H%d]' --reverse

* Get a list of all commits and changes in `sql/deploy`:

        git log -p --format='[%H%d]' --name-status --reverse --decorate=full

* Get the contents of a file at a particular revision:

        git show ecd46ef74a36283d81bdabeb70b4193386d19ea9:sql/deploy/add_widget.sql

* Get the contents of a file at a particular tag:

        git show beta:sql/deploy/add_widget.sql

* Get the contents of a file just prior to a particular revision or tag:

        git show `git log --format='%H' beta^ -1`:sql/deploy/add_widget.sql


Licence
-------

Copyright (c) 2012 iovation Inc.

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
