#!/bin/sh
set -eu

repo=${1:?usage: verify-signed-repo.sh REPO [SUITE] [KEYRING]}
suite=${2:-unstable}
keyring=${3:-$repo/nelix-archive-keyring.gpg}
release="$repo/dists/$suite/Release"
inrelease="$repo/dists/$suite/InRelease"
release_gpg="$repo/dists/$suite/Release.gpg"
signed_sources="$repo/sources.list.signed"

for file in "$release" "$inrelease" "$release_gpg" "$keyring" "$signed_sources"; do
  if [ ! -f "$file" ]; then
    echo "missing signed APT repo file: $file" >&2
    exit 1
  fi
done

if ! command -v gpgv >/dev/null 2>&1; then
  echo "gpgv is required to verify the signed APT repository" >&2
  exit 1
fi

gpgv --keyring "$keyring" "$release_gpg" "$release" >/dev/null 2>&1
gpgv --keyring "$keyring" "$inrelease" >/dev/null 2>&1
grep -q '^deb \[signed-by=.*nelix-archive-keyring\.gpg\] file://' "$signed_sources"

printf 'nelix signed apt repo verify ok: %s\n' "$repo"
