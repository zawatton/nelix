#!/bin/sh
set -eu

version=${1:?usage: make-source.sh VERSION OUT}
out=${2:?usage: make-source.sh VERSION OUT}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

mkdir -p "$(dirname -- "$out")"
rm -f "$out"

tar -C "$root" -czf "$out" \
  --transform "s,^\\.$,nelix-$version," \
  --transform "s,^\\./,nelix-$version/," \
  --exclude-vcs \
  --exclude='./.cache' \
  --exclude='./.claude' \
  --exclude='./.direnv' \
  --exclude='./build' \
  --exclude='./dist' \
  --exclude='./debian/.debhelper' \
  --exclude='./debian/debhelper-build-stamp' \
  --exclude='./debian/elpa-nelix' \
  --exclude='./debian/files' \
  --exclude='./debian/*.debhelper' \
  --exclude='./debian/*.substvars' \
  --exclude='./nelix-apt-public' \
  --exclude='./nelix-apt-repo' \
  --exclude='./nelix-apt-repo-gnupg-test' \
  --exclude='./nelix-rpm-repo' \
  --exclude='./nelix-rpmbuild' \
  --exclude='./result' \
  --exclude='./result-*' \
  --exclude='*.elc' \
  --exclude='*.log' \
  .
printf 'nelix fedora source ok: %s\n' "$out"
