App/Sqitch version 0.940
=======================

This application, `sqitch`, will provide a simple yet robust interface for SQL
change management. The philosophy and functionality is covered over a series
of blog posts published in January, 2012:

* [Simple SQL Change Management](http://justatheory.com/computers/databases/simple-sql-change-management.html)
* [VCS-Enabled SQL Change Management](http://justatheory.com/computers/databases/vcs-sql-change-management.html)
* [SQL Change Management Sans Duplication](http://justatheory.com/computers/databases/sql-change-management-sans-redundancy.html)

But it's not there yet. It's under heavy development. Hopefully it will be
quasi-usable soon, as there is
[a deadline](http://www.pgcon.org/2012/schedule/events/479.en.html). Watch
this space.

Installation
------------

To install this module, type the following:

    perl Build.PL
    ./Build
    ./Build test
    ./Build install

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
