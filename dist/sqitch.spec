Name:           sqitch
Version:        0.9993
Release:        1%{?dist}
Summary:        Sane database change management
License:        MIT
Group:          Development/Libraries
URL:            http://sqitch.org/
Source0:        http://www.cpan.org/modules/by-module/App/App-Sqitch-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
BuildRequires:  perl >= 1:v5.10.0
BuildRequires:  perl(Capture::Tiny) >= 0.12
BuildRequires:  perl(Carp)
BuildRequires:  perl(Class::XSAccessor) >= 1.18
BuildRequires:  perl(Clone)
BuildRequires:  perl(Config)
BuildRequires:  perl(Config::GitLike) >= 1.11
BuildRequires:  perl(constant)
BuildRequires:  perl(DateTime)
BuildRequires:  perl(DateTime::TimeZone)
BuildRequires:  perl(DBI)
BuildRequires:  perl(Devel::StackTrace) >= 1.30
BuildRequires:  perl(Digest::SHA)
BuildRequires:  perl(Encode)
BuildRequires:  perl(Encode::Locale)
BuildRequires:  perl(File::Basename)
BuildRequires:  perl(File::Copy)
BuildRequires:  perl(File::HomeDir)
BuildRequires:  perl(File::Path)
BuildRequires:  perl(File::Spec)
BuildRequires:  perl(File::Temp)
BuildRequires:  perl(Getopt::Long)
BuildRequires:  perl(Hash::Merge)
BuildRequires:  perl(IO::Pager)
BuildRequires:  perl(IPC::Run3)
BuildRequires:  perl(IPC::System::Simple) >= 1.17
BuildRequires:  perl(List::Util)
BuildRequires:  perl(List::MoreUtils)
BuildRequires:  perl(Locale::TextDomain) >= 1.20
BuildRequires:  perl(Module::Build) >= 0.35
BuildRequires:  perl(Moo) >= 1.002000
BuildRequires:  perl(Moo::Role)
BuildRequires:  perl(Moo::sification)
BuildRequires:  perl(namespace::autoclean) >= 0.16
BuildRequires:  perl(parent)
BuildRequires:  perl(overload)
BuildRequires:  perl(Path::Class) >= 0.33
BuildRequires:  perl(PerlIO::utf8_strict)
BuildRequires:  perl(Pod::Find)
BuildRequires:  perl(Pod::Usage)
BuildRequires:  perl(POSIX)
BuildRequires:  perl(Scalar::Util)
BuildRequires:  perl(StackTrace::Auto)
BuildRequires:  perl(strict)
BuildRequires:  perl(String::Formatter)
BuildRequires:  perl(String::ShellQuote)
BuildRequires:  perl(Sub::Exporter)
BuildRequires:  perl(Sub::Exporter::Util)
BuildRequires:  perl(Sys::Hostname)
BuildRequires:  perl(Template::Tiny) >= 0.11
BuildRequires:  perl(Term::ANSIColor) >= 2.02
BuildRequires:  perl(Test::Deep)
BuildRequires:  perl(Test::Dir)
BuildRequires:  perl(Test::Exception)
BuildRequires:  perl(Test::File)
BuildRequires:  perl(Test::File::Contents) >= 0.20
BuildRequires:  perl(Test::MockModule) >= 0.05
BuildRequires:  perl(Test::More) >= 0.94
BuildRequires:  perl(Test::NoWarnings) >= 0.083
BuildRequires:  perl(Throwable) >= 0.200009
BuildRequires:  perl(Time::HiRes)
BuildRequires:  perl(Try::Tiny)
BuildRequires:  perl(Type::Library) >= 0.040
BuildRequires:  perl(Type::Tiny::XS) >= 0.010
BuildRequires:  perl(Type::Utils)
BuildRequires:  perl(Types::Standard)
BuildRequires:  perl(URI)
BuildRequires:  perl(URI::db) >= 0.15
BuildRequires:  perl(User::pwent)
BuildRequires:  perl(utf8)
BuildRequires:  perl(warnings)
Requires:       perl(Class::XSAccessor) >= 1.18
Requires:       perl(Clone)
Requires:       perl(Config)
Requires:       perl(Config::GitLike) >= 1.11
Requires:       perl(constant)
Requires:       perl(DateTime)
Requires:       perl(DateTime::TimeZone)
Requires:       perl(Devel::StackTrace) >= 1.30
Requires:       perl(Digest::SHA)
Requires:       perl(Encode)
Requires:       perl(Encode::Locale)
Requires:       perl(File::Basename)
Requires:       perl(File::Copy)
Requires:       perl(File::HomeDir)
Requires:       perl(File::Path)
Requires:       perl(File::Temp)
Requires:       perl(Getopt::Long)
Requires:       perl(Hash::Merge)
Requires:       perl(IO::Pager)
Requires:       perl(IPC::Run3)
Requires:       perl(IPC::System::Simple) >= 1.17
Requires:       perl(List::Util)
Requires:       perl(List::MoreUtils)
Requires:       perl(Locale::TextDomain) >= 1.20
Requires:       perl(Moo) => 1.002000
Requires:       perl(Moo::Role)
Requires:       perl(Moo::sification)
Requires:       perl(namespace::autoclean) >= 0.16
Requires:       perl(parent)
Requires:       perl(overload)
Requires:       perl(Path::Class)
Requires:       perl(PerlIO::utf8_strict)
Requires:       perl(Pod::Find)
Requires:       perl(Pod::Usage)
Requires:       perl(POSIX)
Requires:       perl(Scalar::Util)
Requires:       perl(StackTrace::Auto)
Requires:       perl(strict)
Requires:       perl(String::Formatter)
Requires:       perl(String::ShellQuote)
Requires:       perl(Sub::Exporter)
Requires:       perl(Sub::Exporter::Util)
Requires:       perl(Sys::Hostname)
Requires:       perl(Template::Tiny) >= 0.11
Requires:       perl(Term::ANSIColor) >= 2.02
Requires:       perl(Throwable) >= 0.200009
Requires:       perl(Try::Tiny)
Requires:       perl(Type::Library) >= 0.040
Requires:       perl(Type::Tiny::XS) >= 0.010
Requires:       perl(Type::Utils)
Requires:       perl(Types::Standard)
Requires:       perl(URI)
Requires:       perl(URI::db) >= 0.15
Requires:       perl(User::pwent)
Requires:       perl(utf8)
Requires:       perl(warnings)
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))
Provides:       sqitch

%define etcdir %(%{__perl} -MConfig -E 'say "$Config{prefix}/etc"')

%description
This application, `sqitch`, provides a simple yet robust interface for
database change management. The philosophy and functionality is inspired by
Git.

%prep
%setup -q -n App-Sqitch-%{version}

%build
%{__perl} Build.PL installdirs=vendor destdir=$RPM_BUILD_ROOT
./Build

%install
rm -rf $RPM_BUILD_ROOT

./Build install create_packlist=0
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

%check
./Build test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc Changes META.json README.md
%{perl_vendorlib}/*
%{_mandir}/man3/*
%{_bindir}/*
%config %{etcdir}/*

%package pg
Summary:        Sane database change management for PostgreSQL
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       postgresql >= 8.4.0
Requires:       perl(DBI)
Requires:       perl(DBD::Pg) >= 2.0.0
Provides:       sqitch-pg

%description pg
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqitch PostgreSQL support.

%files pg
# No additional files required.

%package sqlite
Summary:        Sane database change management for SQLite
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       sqlite
Requires:       perl(DBI)
Requires:       perl(DBD::SQLite) >= 1.37
Provides:       sqitch-sqlite

%description sqlite
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqitch SQLite support.

%files sqlite
# No additional files required.

%package oracle
Summary:        Sane database change management for Oracle
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       oracle-instantclient11.2-sqlplus
Requires:       perl(DBI)
Requires:       perl(DBD::Oracle) >= 1.23
Provides:       sqitch-oracle

%description oracle
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqitch Oracle support.

%files oracle
# No additional files required.

%package mysql
Summary:        Sane database change management for MySQL
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       mysql >= 5.1.0
Requires:       perl(DBI)
Requires:       perl(DBD::mysql) >= 4.018
Requires:       perl(MySQL::Config)
Provides:       sqitch-mysql

%description mysql
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqitch MySQL support.

%files mysql
# No additional files required.

%package firebird
Summary:        Sane database change management for Firebird
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       firebird >= 2.5.0
Requires:       perl(DBI)
Requires:       perl(DBD::Firebird) >= 1.11
Requires:       perl(Time::HiRes)
Requires:       perl(Time::Local)
BuildRequires:  firebird >= 2.5.0
Provides:       sqitch-firebird

%description firebird
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqitch Firebird support.

%files firebird
# No additional files required.

%package vertica
Summary:        Sane database change management for Vertica
Group:          Development/Libraries
Requires:       sqitch >= %{version}
Requires:       libverticaodbc.so
Requires:       /opt/vertica/bin/vsql
Requires:       perl(DBI)
Requires:       perl(DBD::ODBC) >= 1.43
Provides:       sqitch-vertica

%description vertica
Sqitch provides a simple yet robust interface for database change management.
The philosophy and functionality is inspired by Git. This package bundles the
Sqitch Vertica support.

%files vertica
# No additional files required.

%changelog
* Wed May 20 2015 David E. Wheeler <david.wheeler@iovation.com> 0.9992-1
- Upgrade to v0.9992.
- Add perl(DateTime::TimeZone).
- Add Provides.
- Replace requirement for firebird-classic with firebird.
- Replace requirement for vertica-client with /opt/vertica/bin/vsql and
  libverticaodbc.so.

* Fri Mar 3 2015 David E. Wheeler <david.wheeler@iovation.com> 0.9991-1
- Upgrade to v0.9991.
- Reduced required MySQL version to 5.1.

* Thu Feb 12 2015 David E. Wheeler <david.wheeler@iovation.com> 0.999-1
- Upgrade to v0.999.

* Thu Jan 15 2015 David E. Wheeler <david.wheeler@iovation.com> 0.998-1
- Upgrade to v0.998.
- Require Path::Class v0.33 when building.

* Tue Nov 4 2014 David E. Wheeler <david.wheeler@iovation.com> 0.997-1
- Upgrade to v0.997.

* Fri Sep 5 2014 David E. Wheeler <david.wheeler@iovation.com> 0.996-1
- Upgrade to v0.996.
- Remove Moose and Mouse dependencies.
- Add Moo dependencies.
- Add Type::Library and related module dependencies.
- Switch from Digest::SHA1 to Digest::SHA.
- Require the Moo-backed version of Config::GitLike.
- Remove Role module dependencies.
- Require URI::db v0.15.
- Add sqitch-vertica.

* Sun Jul 13 2014 David E. Wheeler <david.wheeler@iovation.com> 0.995-1
- Upgrade to v0.995.

* Thu Jun 19 2014 David E. Wheeler <david.wheeler@iovation.com> 0.994-1
- Upgrade to v0.994.

* Wed Jun 4 2014 David E. Wheeler <david.wheeler@iovation.com> 0.993-1
- Upgrade to v0.993.

* Tue Mar 4 2014 David E. Wheeler <david.wheeler@iovation.com> 0.992-1
- Upgrade to v0.992.

* Thu Jan 16 2014 David E. Wheeler <david.wheeler@iovation.com> 0.991-1
- Upgrade to v0.991.
- Remove File::Which from sqitch-firebird.

* Fri Jan 4 2014 David E. Wheeler <david.wheeler@iovation.com> 0.990-1
- Upgrade to v0.990.
- Add sqitch-firebird.
- Add target command and arguments.
- Add support for arbitrary change script templating.
- Add --open-editor option.

* Thu Nov 21 2013 David E. Wheeler <david.wheeler@iovation.com> 0.983-1
- Upgrade to v0.983.
- Require DBD::Pg 2.0.0 or higher.

* Wed Sep 18 2013 David E. Wheeler <david.wheeler@iovation.com> 0.982-2
- No longer include template files ending in .default in the RPM.
- All files in the etc dir now treated as configuration files.
- The etc and inc files are no longer treated as documentation.

* Wed Sep 11 2013 David E. Wheeler <david.wheeler@iovation.com> 0.982-1
- Upgrade to v0.982.
- Require Clone.

* Thu Sep 5 2013 David E. Wheeler <david.wheeler@iovation.com> 0.981-1
- Upgrade to v0.981.

* Tue Aug 28 2013 David E. Wheeler <david.wheeler@iovation.com> 0.980-1
- Upgrade to v0.980.
- Require Encode::Locale.
- Require DBD::SQLite 1.37.
- Require PostgreSQL 8.4.0.
- Remove FindBin requirement.
- Add sqitch-mysql.

* Wed Jul 3 2013 David E. Wheeler <david.wheeler@iovation.com> 0.973-1
- Upgrade to v0.973.

* Fri May 31 2013 David E. Wheeler <david.wheeler@iovation.com> 0.972-1
- Upgrade to v0.972.

* Sat May 18 2013 David E. Wheeler <david.wheeler@iovation.com> 0.971-1
- Upgrade to v0.971.

* Wed May 8 2013 David E. Wheeler <david.wheeler@iovation.com> 0.970-1
- Upgrade to v0.970.
- Add sqitch-oracle.

* Tue Apr 23 2013 David E. Wheeler <david.wheeler@iovation.com> 0.965-1
- Upgrade to v0.965.

* Mon Apr 15 2013 David E. Wheeler <david.wheeler@iovation.com> 0.964-1
- Upgrade to v0.964.

* Thu Apr 12 2013 David E. Wheeler <david.wheeler@iovation.com> 0.963-1
- Upgrade to v0.963.
- Add missing dependency on Devel::StackTrace 1.30.
- Remove dependency on Git::Wrapper.

* Tue Apr 10 2013 David E. Wheeler <david.wheeler@iovation.com> 0.962-1
- Upgrade to v0.962.

* Tue Apr 9 2013 David E. Wheeler <david.wheeler@iovation.com> 0.961-1
- Upgrade to v0.961.

* Mon Apr 8 2013 David E. Wheeler <david.wheeler@iovation.com> 0.960-2
- Add missing dependency on Git::Wrapper.

* Fri Apr 5 2013 David E. Wheeler <david.wheeler@iovation.com> 0.960-1
- Upgrade to v0.960.
- Add sqitch-sqlite.

* Thu Feb 21 2013 David E. Wheeler <david.wheeler@iovation.com> 0.953-1
- Upgrade to v0.953.

* Fri Jan 12 2013 David E. Wheeler <david.wheeler@iovation.com> 0.952-1
- Upgrade to v0.952.

* Mon Jan 7 2013 David E. Wheeler <david.wheeler@iovation.com> 0.951-1
- Upgrade to v0.951.

* Thu Jan 3 2013 David E. Wheeler <david.wheeler@iovation.com> 0.950-1
- Upgrade to v0.950.

* Fri Dec 3 2012 David E. Wheeler <david.wheeler@iovation.com> 0.940-1
- Upgrade to v0.940.

* Fri Oct 12 2012 David E. Wheeler <david.wheeler@iovation.com> 0.938-1
- Upgrade to v0.938.

* Tue Oct 9 2012 David E. Wheeler <david.wheeler@iovation.com> 0.937-1
- Upgrade to v0.937.

* Tue Oct 9 2012 David E. Wheeler <david.wheeler@iovation.com> 0.936-1
- Upgrade to v0.936.

* Tue Oct 2 2012 David E. Wheeler <david.wheeler@iovation.com> 0.935-1
- Upgrade to v0.935.

* Fri Sep 28 2012 David E. Wheeler <david.wheeler@iovation.com> 0.934-1
- Upgrade to v0.934.

* Thu Sep 27 2012 David E. Wheeler <david.wheeler@iovation.com> 0.933-1
- Upgrade to v0.933.

* Wed Sep 26 2012 David E. Wheeler <david.wheeler@iovation.com> 0.932-1
- Upgrade to v0.932.

* Tue Sep 25 2012 David E. Wheeler <david.wheeler@iovation.com> 0.931-1
- Upgrade to v0.931.

* Fri Aug 31 2012 David E. Wheeler <david.wheeler@iovation.com> 0.930-1
- Upgrade to v0.93.

* Thu Aug 30 2012 David E. Wheeler <david.wheeler@iovation.com> 0.922-1
- Upgrade to v0.922.

* Wed Aug 29 2012 David E. Wheeler <david.wheeler@iovation.com> 0.921-1
- Upgrade to v0.921.

* Tue Aug 28 2012 David E. Wheeler <david.wheeler@iovation.com> 0.920-1
- Upgrade to v0.92.

* Tue Aug 28 2012 David E. Wheeler <david.wheeler@iovation.com> 0.913-1
- Upgrade to v0.913.

* Mon Aug 27 2012 David E. Wheeler <david.wheeler@iovation.com> 0.912-1
- Upgrade to v0.912.

* Wed Aug 23 2012 David E. Wheeler <david.wheeler@iovation.com> 0.911-1
- Upgrade to v0.911.

* Wed Aug 22 2012 David E. Wheeler <david.wheeler@iovation.com> 0.91-1
- Upgrade to v0.91.

* Mon Aug 20 2012 David E. Wheeler <david.wheeler@iovation.com> 0.902-1
- Upgrade to v0.902.

* Mon Aug 20 2012 David E. Wheeler <david.wheeler@iovation.com> 0.901-1
- Upgrade to v0.901.

* Mon Aug 13 2012 David E. Wheeler <david.wheeler@iovation.com> 0.82-2
- Require Config::GitLike 1.09, which offers better encoding support an other
  bug fixes.

* Fri Aug 03 2012 David E. Wheeler <david.wheeler@iovation.com> 0.82-2
- Specfile autogenerated by cpanspec 1.78.
