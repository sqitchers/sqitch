%define cpanversion 0.921
Name:           sqitch
Version:        %(%{__perl} -E 'say sprintf "%.3f", %{cpanversion}')
Release:        1%{?dist}
Summary:        Sane database change management
License:        MIT
Group:          Development/Libraries
URL:            http://sqitch.org/
Source0:        http://www.cpan.org/modules/by-module/App/App-Sqitch-%{cpanversion}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
BuildRequires:  perl >= 1:v5.10.1
BuildRequires:  perl(Capture::Tiny) >= 0.12
BuildRequires:  perl(Config)
BuildRequires:  perl(Config::GitLike) >= 1.09
BuildRequires:  perl(constant)
BuildRequires:  perl(DateTime)
BuildRequires:  perl(DBI)
BuildRequires:  perl(Digest::SHA1)
BuildRequires:  perl(Encode)
BuildRequires:  perl(File::Basename)
BuildRequires:  perl(File::Copy)
BuildRequires:  perl(File::HomeDir)
BuildRequires:  perl(File::Path)
BuildRequires:  perl(File::Spec)
BuildRequires:  perl(File::Temp)
BuildRequires:  perl(Getopt::Long)
BuildRequires:  perl(Hash::Merge)
BuildRequires:  perl(IO::Pager)
BuildRequires:  perl(IPC::System::Simple) >= 1.17
BuildRequires:  perl(List::Util)
BuildRequires:  perl(Locale::TextDomain) >= 1.20
BuildRequires:  perl(Module::Build) >= 0.35
BuildRequires:  perl(Moose) >= 2.0300
BuildRequires:  perl(Moose::Meta::Attribute::Native) >= 2.0300
BuildRequires:  perl(Moose::Meta::TypeConstraint::Parameterizable) >= 2.0300
BuildRequires:  perl(Moose::Util::TypeConstraints) >= 2.0300
BuildRequires:  perl(MooseX::Types::Path::Class) >= 0.05
BuildRequires:  perl(namespace::autoclean) >= 0.11
BuildRequires:  perl(parent)
BuildRequires:  perl(overload)
BuildRequires:  perl(Path::Class)
BuildRequires:  perl(Pod::Find)
BuildRequires:  perl(Pod::Usage)
BuildRequires:  perl(POSIX)
BuildRequires:  perl(Role::HasMessage) >= 0.005
BuildRequires:  perl(Role::Identifiable::HasIdent) >= 0.005
BuildRequires:  perl(Role::Identifiable::HasTags) >= 0.005
BuildRequires:  perl(StackTrace::Auto)
BuildRequires:  perl(strict)
BuildRequires:  perl(String::Formatter)
BuildRequires:  perl(Sub::Exporter)
BuildRequires:  perl(Sub::Exporter::Util)
BuildRequires:  perl(Sys::Hostname)
BuildRequires:  perl(Template::Tiny) >= 0.11
BuildRequires:  perl(Term::ANSIColor) >= 2.02
BuildRequires:  perl(Test::Deep)
BuildRequires:  perl(Test::Dir)
BuildRequires:  perl(Test::Exception)
BuildRequires:  perl(Test::File)
BuildRequires:  perl(Test::File::Contents) >= 0.05
BuildRequires:  perl(Test::MockModule) >= 0.05
BuildRequires:  perl(Test::More) >= 0.94
BuildRequires:  perl(Test::NoWarnings) >= 0.083
BuildRequires:  perl(Throwable)
BuildRequires:  perl(Try::Tiny)
BuildRequires:  perl(URI)
BuildRequires:  perl(User::pwent)
BuildRequires:  perl(utf8)
BuildRequires:  perl(warnings)
Requires:       perl(Config)
Requires:       perl(Config::GitLike) >= 1.09
Requires:       perl(constant)
Requires:       perl(DateTime)
Requires:       perl(Digest::SHA1)
Requires:       perl(Encode)
Requires:       perl(File::Basename)
Requires:       perl(File::Copy)
Requires:       perl(File::HomeDir)
Requires:       perl(File::Path)
Requires:       perl(File::Temp)
Requires:       perl(FindBin)
Requires:       perl(Getopt::Long)
Requires:       perl(Hash::Merge)
Requires:       perl(IO::Pager)
Requires:       perl(IPC::System::Simple) >= 1.17
Requires:       perl(List::Util)
Requires:       perl(Locale::TextDomain) >= 1.20
Requires:       perl(Moose) >= 2.0300
Requires:       perl(Moose::Meta::Attribute::Native) >= 2.0300
Requires:       perl(Moose::Meta::TypeConstraint::Parameterizable) >= 2.0300
Requires:       perl(Moose::Util::TypeConstraints) >= 2.0300
Requires:       perl(MooseX::Types::Path::Class) >= 0.05
Requires:       perl(namespace::autoclean) >= 0.11
Requires:       perl(parent)
Requires:       perl(overload)
Requires:       perl(Path::Class)
Requires:       perl(Pod::Find)
Requires:       perl(Pod::Usage)
Requires:       perl(POSIX)
Requires:       perl(Role::HasMessage) >= 0.005
Requires:       perl(Role::Identifiable::HasIdent) >= 0.005
Requires:       perl(Role::Identifiable::HasTags) >= 0.005
Requires:       perl(StackTrace::Auto)
Requires:       perl(strict)
Requires:       perl(String::Formatter)
Requires:       perl(Sub::Exporter)
Requires:       perl(Sub::Exporter::Util)
Requires:       perl(Sys::Hostname)
Requires:       perl(Template::Tiny) >= 0.11
Requires:       perl(Term::ANSIColor) >= 2.02
Requires:       perl(Throwable)
Requires:       perl(Try::Tiny)
Requires:       perl(URI)
Requires:       perl(User::pwent)
Requires:       perl(utf8)
Requires:       perl(warnings)
Requires:       perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))

%define etcdir %(%{__perl} -MConfig -E 'say "$Config{prefix}/etc"')

%description
This application, `sqitch`, provides a simple yet robust interface for
database change management. The philosophy and functionality is inspired by
Git.

%prep
%setup -q -n App-Sqitch-%{cpanversion}

%build
%{__perl} Build.PL installdirs=vendor
./Build

%install
rm -rf $RPM_BUILD_ROOT

./Build install destdir=$RPM_BUILD_ROOT create_packlist=0
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

%check
./Build test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc Changes etc META.json inc README.md
%{perl_vendorlib}/*
%{_mandir}/man3/*
%{_bindir}/*
%{etcdir}/*

%changelog
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
