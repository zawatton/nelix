#!/bin/sh
set -eu

tarball=${1:?usage: verify-source.sh TARBALL VERSION}
version=${2:?usage: verify-source.sh TARBALL VERSION}
prefix="nelix-$version"

if [ ! -f "$tarball" ]; then
  echo "missing Fedora source tarball: $tarball" >&2
  exit 1
fi

contents=$(mktemp)
trap 'rm -f "$contents"' EXIT HUP INT TERM
tar -tzf "$tarball" >"$contents"

for path in \
  "$prefix/Makefile" \
  "$prefix/LICENSE" \
  "$prefix/bin/nelix" \
  "$prefix/debian/nelix.1" \
  "$prefix/nelix.el" \
  "$prefix/registry/packages/system/ripgrep.el" \
  "$prefix/registry/packages/system/git.el" \
  "$prefix/registry/packages/system/curl.el" \
  "$prefix/registry/packages/system/jq.el" \
  "$prefix/packaging/fedora/publish-static.sh" \
  "$prefix/packaging/fedora/verify-public-tree.sh" \
  "$prefix/packaging/verify-publication-urls.sh" \
  "$prefix/packaging/fedora/nelix.spec"
do
  if ! grep -Fxq "$path" "$contents"; then
    echo "Fedora source tarball is missing required file: $path" >&2
    exit 1
  fi
done

tar -xOzf "$tarball" "$prefix/bin/nelix" | grep -q 'NELIX_NELISP_AOT:-auto' || {
  echo "Fedora source tarball bin/nelix is missing default AOT cache mode" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/bin/nelix" | grep -q 'NELIX_NELISP_AOT=0 to force the slower direct NeLisp path' || {
  echo "Fedora source tarball bin/nelix is missing direct NeLisp opt-out diagnostic" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/fedora/nelix.spec" | grep -q 'NELIX_LISPDIR="$PWD" bin/nelix --json version' || {
  echo "Fedora source tarball spec is missing CLI version check" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/fedora/verify-public-tree.sh" | grep -q 'set FEDORA_PUBLIC_URL to the real published Fedora repository URL' || {
  echo "Fedora source tarball public tree verifier is missing real URL refusal" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/fedora/verify-public-tree.sh" | grep -q 'public Fedora tree is missing expected-version RPM payload' || {
  echo "Fedora source tarball public tree verifier is missing expected-version payload check" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/fedora/public-url-smoke.sh" | grep -q 'rpm -q --qf' || {
  echo "Fedora source tarball public URL smoke is missing installed RPM version check" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/fedora/dnf-smoke.sh" | grep -q 'rpm -q --qf' || {
  echo "Fedora source tarball local dnf smoke is missing installed RPM version check" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/verify-publication-urls.sh" | grep -q 'set $name to the real published repository URL' || {
  echo "Fedora source tarball publication URL guard is missing APT URL refusal" >&2
  exit 1
}

tar -xOzf "$tarball" "$prefix/packaging/verify-publication-urls.sh" | grep -q 'check_url FEDORA_PUBLIC_URL' || {
  echo "Fedora source tarball publication URL guard is missing Fedora URL check" >&2
  exit 1
}

if grep -E '(^|/)(\\.git|\\.cache|\\.claude|\\.direnv)(/|$)' "$contents"; then
  echo "Fedora source tarball contains local metadata/cache directories" >&2
  exit 1
fi

if grep -E '(^|/)debian/(\\.debhelper|elpa-nelix)(/|$)' "$contents"; then
  echo "Fedora source tarball contains Debian build output directories" >&2
  exit 1
fi

if grep -E '(^|/)debian/(files|debhelper-build-stamp|.*\\.(debhelper|substvars))$' "$contents"; then
  echo "Fedora source tarball contains Debian build output files" >&2
  exit 1
fi

if grep -E '(^|/)(nelix-apt-public|nelix-apt-repo|nelix-apt-repo-gnupg-test|nelix-rpm-repo|nelix-rpmbuild)(/|$)' "$contents"; then
  echo "Fedora source tarball contains local package repository outputs" >&2
  exit 1
fi

if grep -E '\\.(elc|log)$' "$contents"; then
  echo "Fedora source tarball contains compiled or log files" >&2
  exit 1
fi

printf 'nelix fedora source verify ok: %s\n' "$tarball"
