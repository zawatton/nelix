#!/bin/sh
set -eu

topdir=${1:?usage: build-rpm.sh TOPDIR VERSION SPEC}
version=${2:?usage: build-rpm.sh TOPDIR VERSION SPEC}
spec=${3:?usage: build-rpm.sh TOPDIR VERSION SPEC}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild is required; on Fedora run: sudo dnf install rpm-build" >&2
  exit 1
fi

mkdir -p "$topdir/BUILD" "$topdir/BUILDROOT" "$topdir/RPMS" "$topdir/SOURCES" "$topdir/SPECS" "$topdir/SRPMS"
"$script_dir/make-source.sh" "$version" "$topdir/SOURCES/nelix-$version.tar.gz"
"$script_dir/verify-source.sh" "$topdir/SOURCES/nelix-$version.tar.gz" "$version"

abs_topdir=$(CDPATH= cd -- "$topdir" && pwd)
abs_spec=$(CDPATH= cd -- "$(dirname -- "$spec")" && pwd)/$(basename -- "$spec")

rpmbuild --define "_topdir $abs_topdir" -ba "$abs_spec"
find "$topdir/RPMS" "$topdir/SRPMS" -type f \( -name '*.rpm' -o -name '*.src.rpm' \) -print | sort
