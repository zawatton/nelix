#!/bin/sh
set -eu

repo=${1:?usage: verify-repo.sh REPO [SUITE]}
suite=${2:-unstable}
component=${NELIX_APT_COMPONENT:-main}
architecture=${NELIX_APT_ARCHITECTURE:-all}
binary_dir="$repo/dists/$suite/$component/binary-$architecture"
packages="$binary_dir/Packages"
packages_gz="$binary_dir/Packages.gz"
release="$repo/dists/$suite/Release"
sources="$repo/sources.list"

for file in "$packages" "$packages_gz" "$release" "$sources"; do
  if [ ! -f "$file" ]; then
    echo "missing APT repo file: $file" >&2
    exit 1
  fi
done

grep -q '^Package: elpa-nelix$' "$packages"
grep -q '^Version: ' "$packages"
grep -q '^Architecture: all$' "$packages"
grep -q "^Filename: pool/$component/.*/elpa-nelix_.*_all\\.deb$" "$packages"
grep -q '^SHA256:' "$release"
grep -q " $suite $component" "$sources"

gzip -dc "$packages_gz" | cmp -s - "$packages"

deb_path=$(awk '
  $1 == "Filename:" { print $2; exit }
' "$packages")

if [ ! -f "$repo/$deb_path" ]; then
  echo "missing package payload referenced by Packages: $deb_path" >&2
  exit 1
fi

printf 'nelix apt repo verify ok: %s\n' "$repo"
