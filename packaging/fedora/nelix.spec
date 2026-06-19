Name:           nelix
Version:        0.1.0
Release:        1%{?dist}
Summary:        Emacs Lisp package manager backed by the Nix store

License:        GPL-3.0-or-later
URL:            https://github.com/zawatton/nelix
Source0:        %{url}/archive/v%{version}/%{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  emacs
BuildRequires:  make

Requires:       emacs-filesystem
Recommends:     git
Recommends:     curl
Recommends:     ca-certificates
Suggests:       nix
Suggests:       nelisp

%description
Nelix is a package manager configured in Emacs Lisp and backed by the
Nix store.  It installs Linux user-space tools and Emacs Lisp packages
from one manifest-oriented interface.

%package -n emacs-nelix
Summary:        Emacs Lisp files for Nelix
Requires:       emacs-filesystem
Recommends:     nelix

%description -n emacs-nelix
This package installs the Emacs Lisp runtime files for Nelix.

%prep
%autosetup -n %{name}-%{version}

%build
:

%install
%make_install \
  prefix=%{_prefix} \
  bindir=%{_bindir} \
  lispdir=%{_emacs_sitelispdir}/nelix \
  docdir=%{_docdir}/nelix

install -Dpm 0644 debian/nelix.1 %{buildroot}%{_mandir}/man1/nelix.1
rm -f %{buildroot}%{_docdir}/nelix/LICENSE

%check
emacs -Q --batch -L . -L test -L scripts -l nelix --eval "(require 'nelix)"
grep -q 'NELIX_NELISP_AOT:-auto' bin/nelix
grep -q 'NELIX_NELISP_AOT=0 to force the slower direct NeLisp path' bin/nelix
NELIX_LISPDIR="$PWD" bin/nelix --json version | grep -q '"status":"ok"'

%files
%license LICENSE
%{_bindir}/nelix
%{_docdir}/nelix
%{_mandir}/man1/nelix.1*

%files -n emacs-nelix
%doc README.org
%{_emacs_sitelispdir}/nelix

%changelog
* Wed Jun 17 2026 zawatton <zawatton@example.invalid> - 0.1.0-1
- Initial Fedora packaging skeleton.
