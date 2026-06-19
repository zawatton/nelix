#!/bin/sh
set -eu

repo=${1:?usage: dnf-smoke.sh REPO [EXPECTED_VERSION]}
expected_version=${2:-}
repo_abs=$(CDPATH= cd -- "$repo" && pwd)

for tool in dnf rpm emacs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for Fedora dnf smoke" >&2
    exit 1
  fi
done

test -f "$repo_abs/repodata/repomd.xml"

dnf -y \
  --disablerepo='*' \
  --repofrompath=nelix-local,"file://$repo_abs" \
  --setopt=nelix-local.gpgcheck=0 \
  --setopt=nelix-local.repo_gpgcheck=0 \
  --enablerepo=nelix-local \
  install nelix emacs-nelix

rpm -q nelix emacs-nelix
if [ -n "$expected_version" ]; then
  if [ "$(rpm -q --qf '%{VERSION}' nelix)" != "$expected_version" ]; then
    echo "installed nelix RPM version does not match expected version: $expected_version" >&2
    exit 1
  fi
  if [ "$(rpm -q --qf '%{VERSION}' emacs-nelix)" != "$expected_version" ]; then
    echo "installed emacs-nelix RPM version does not match expected version: $expected_version" >&2
    exit 1
  fi
fi
emacs -Q --batch -L /usr/share/emacs/site-lisp/nelix \
  --eval "(require 'nelix)" \
  --eval "(require 'nelix-dsl)" \
  --eval "(message \"nelix Fedora load smoke ok\")"
nelix --help >/dev/null

printf 'nelix fedora dnf smoke ok: %s\n' "$repo_abs"
