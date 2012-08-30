%define cpanversion 0.922
Name:           sqitch-pg
Version:        %(%{__perl} -E 'say sprintf "%.3f", %{cpanversion}')
Release:        1%{?dist}
Summary:        Sane PostgreSQL database change management
License:        MIT
Group:          Development/Libraries
URL:            http://sqitch.org/
BuildArch:      noarch
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
Requires:       sqitch >= %{version}
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

* Sat Aug 04 2012 David E. Wheeler <david.wheeler@iovation.com> 0.82-1
- First release.
