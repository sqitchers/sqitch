App/Sqitch version 0.10
=======================

This application, `sqitch`, will provide a simple yet robust interface for SQL
change management. The philosophy and functionality is covered over a series
of blog posts published in January, 2012:

* [Simple SQL Change Management](http://justatheory.com/computers/databases/simple-sql-change-management.html)

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



Copyright and Licence
---------------------

Copyright (c) 2012 iovation, Inc. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

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



