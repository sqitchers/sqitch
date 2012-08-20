Name:           sqitch-pg
Version:        0.902
Release:        1%{?dist}
Summary:        Sane PostgreSQL database change management
License:        MIT
Group:          Development/Libraries
URL:            http://sqitch.org/
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
Requires:       sqitch >= 0.902
Requires:       postgresql91
Requires:       perl(DBI)
Requires:       perl(DBD::Pg)

%description
Sqitch provides a simple yet robust interface for database change
management. The philosophy and functionality is inspired by Git. This
package bundles the Sqith PostgreSQL support.

%prep

%build

%install

%check

%clean

%files

%changelog
* Mon Aug 20 2012 David E. Wheeler <david.wheeler@iovation.com> 0.902-1
- Upgrade to v0.902.

* Mon Aug 20 2012 David E. Wheeler <david.wheeler@iovation.com> 0.901-1
- Upgrade to v0.901.

* Sat Aug 04 2012 David E. Wheeler <david.wheeler@iovation.com> 0.82-1
- First release.
