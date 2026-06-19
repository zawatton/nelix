#!/bin/sh
set -eu

topdir=${1:?usage: make-repo.sh TOPDIR OUTDIR}
out=${2:?usage: make-repo.sh TOPDIR OUTDIR}

if ! command -v createrepo_c >/dev/null 2>&1; then
  echo "createrepo_c is required; on Fedora run: sudo dnf install createrepo_c" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
find "$topdir/RPMS" -type f -name '*.rpm' -exec cp {} "$out/" \;

if ! find "$out" -maxdepth 1 -type f -name '*.rpm' -print -quit | grep -q .; then
  echo "no RPM payloads found under $topdir/RPMS" >&2
  exit 1
fi

createrepo_c "$out"
test -f "$out/repodata/repomd.xml"
printf 'nelix fedora repo ok: %s\n' "$out"
