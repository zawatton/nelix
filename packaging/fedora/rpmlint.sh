#!/bin/sh
set -eu

topdir=${1:?usage: rpmlint.sh TOPDIR SPEC}
spec=${2:?usage: rpmlint.sh TOPDIR SPEC}

if ! command -v rpmlint >/dev/null 2>&1; then
  echo "rpmlint is required; on Fedora run: sudo dnf install rpmlint" >&2
  exit 1
fi

set -- "$spec"
for rpm in $(find "$topdir/RPMS" "$topdir/SRPMS" -type f \( -name '*.rpm' -o -name '*.src.rpm' \) | sort); do
  set -- "$@" "$rpm"
done

rpmlint "$@"
