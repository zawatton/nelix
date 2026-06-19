#!/bin/sh
set -eu

tree=${1:?usage: verify-public-tree.sh TREE BASE_URL [EXPECTED_VERSION]}
base_url=${2:?usage: verify-public-tree.sh TREE BASE_URL [EXPECTED_VERSION]}
expected_version=${3:-}

base_url=${base_url%/}
case "$base_url" in
  *example.invalid*|"")
    echo "set FEDORA_PUBLIC_URL to the real published Fedora repository URL" >&2
    exit 1
    ;;
  https://*) ;;
  http://*)
    if [ "${NELIX_ALLOW_INSECURE_PUBLIC_URL:-}" != 1 ]; then
      echo "refusing insecure public Fedora URL without NELIX_ALLOW_INSECURE_PUBLIC_URL=1: $base_url" >&2
      exit 1
    fi
    ;;
  *)
    echo "FEDORA_PUBLIC_URL must be an http(s) repository URL, got: $base_url" >&2
    exit 1
    ;;
esac

for file in \
  "$tree/repodata/repomd.xml" \
  "$tree/nelix-fedora.repo"
do
  if [ ! -f "$file" ]; then
    echo "missing public Fedora tree file: $file" >&2
    exit 1
  fi
done

if find "$tree" \( -name '.gnupg*' -o -name 'private-keys-v1.d' \) -print -quit | grep -q .; then
  echo "public Fedora tree contains GPG test or secret material: $tree" >&2
  exit 1
fi

for pattern in \
  'nelix-*.rpm' \
  'emacs-nelix-*.rpm'
do
  if ! find "$tree" -maxdepth 1 -type f -name "$pattern" -print -quit | grep -q .; then
    echo "public Fedora tree is missing RPM payload matching $pattern" >&2
    exit 1
  fi
done

if [ -n "$expected_version" ]; then
  for pattern in \
    "nelix-${expected_version}-*.rpm" \
    "emacs-nelix-${expected_version}-*.rpm"
  do
    if ! find "$tree" -maxdepth 1 -type f -name "$pattern" -print -quit | grep -q .; then
      echo "public Fedora tree is missing expected-version RPM payload matching $pattern" >&2
      exit 1
    fi
  done
fi

grep -Fxq "[nelix]" "$tree/nelix-fedora.repo"
grep -Fxq "baseurl=$base_url" "$tree/nelix-fedora.repo" || {
  echo "public Fedora repo file does not match FEDORA_PUBLIC_URL" >&2
  exit 1
}
grep -Eq '^gpgcheck=[01]$' "$tree/nelix-fedora.repo"
grep -Eq '^repo_gpgcheck=[01]$' "$tree/nelix-fedora.repo"

if command -v rpm >/dev/null 2>&1; then
  rpm -qp --qf '%{NAME}\n' "$tree"/*.rpm | grep -Fxq nelix
  rpm -qp --qf '%{NAME}\n' "$tree"/*.rpm | grep -Fxq emacs-nelix
  if [ -n "$expected_version" ]; then
    rpm -qp --qf '%{NAME} %{VERSION}\n' "$tree"/*.rpm |
      grep -Fxq "nelix $expected_version"
    rpm -qp --qf '%{NAME} %{VERSION}\n' "$tree"/*.rpm |
      grep -Fxq "emacs-nelix $expected_version"
  fi
fi

printf 'nelix public fedora tree verify ok: %s %s\n' "$tree" "$base_url"
