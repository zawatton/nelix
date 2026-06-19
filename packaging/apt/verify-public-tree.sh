#!/bin/sh
set -eu

tree=${1:?usage: verify-public-tree.sh TREE BASE_URL [SUITE] [EXPECTED_VERSION]}
base_url=${2:?usage: verify-public-tree.sh TREE BASE_URL [SUITE] [EXPECTED_VERSION]}
suite=${3:-unstable}
expected_version=${4:-}
component=${NELIX_APT_COMPONENT:-main}
architecture=${NELIX_APT_ARCHITECTURE:-all}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

verify_deb_payload() {
  deb=$1
  dpkg-deb --fsys-tarfile "$deb" | tar -tf - |
    grep -Fxq './usr/bin/nelix' || {
      echo "public APT payload is missing /usr/bin/nelix: $deb" >&2
      exit 1
    }
  for recipe in curl git jq ripgrep; do
    dpkg-deb --fsys-tarfile "$deb" | tar -tf - |
      grep -Fxq "./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/$recipe.el" || {
        echo "public APT payload is missing packaged registry recipe: $recipe" >&2
        exit 1
      }
  done
  dpkg-deb --fsys-tarfile "$deb" |
    tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh |
    grep -Fq 'packaged_install native install ripgrep' || {
      echo "public APT payload native CLI gate is missing packaged ripgrep install smoke" >&2
      exit 1
    }
  dpkg-deb --fsys-tarfile "$deb" |
    tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh |
    grep -Fq 'packaged-rg-ok --nelix-gate' || {
      echo "public APT payload native CLI gate is missing packaged rg execution smoke" >&2
      exit 1
    }
}

base_url=${base_url%/}
case "$base_url" in
  *example.invalid*|"")
    echo "set APT_PUBLIC_URL to the real published APT repository URL" >&2
    exit 1
    ;;
  https://*) ;;
  http://*)
    if [ "${NELIX_ALLOW_INSECURE_PUBLIC_URL:-}" != 1 ]; then
      echo "refusing insecure public APT URL without NELIX_ALLOW_INSECURE_PUBLIC_URL=1: $base_url" >&2
      exit 1
    fi
    ;;
  *)
    echo "APT_PUBLIC_URL must be an http(s) repository URL, got: $base_url" >&2
    exit 1
    ;;
esac

for file in \
  "$tree/nelix-archive-keyring.gpg" \
  "$tree/sources.list.https" \
  "$tree/dists/$suite/Release" \
  "$tree/dists/$suite/InRelease" \
  "$tree/dists/$suite/Release.gpg" \
  "$tree/dists/$suite/$component/binary-$architecture/Packages" \
  "$tree/dists/$suite/$component/binary-$architecture/Packages.gz"
do
  if [ ! -f "$file" ]; then
    echo "missing public APT tree file: $file" >&2
    exit 1
  fi
done

if find "$tree" \( -name '.gnupg*' -o -name 'private-keys-v1.d' \) -print -quit | grep -q .; then
  echo "public APT tree contains GPG test or secret material: $tree" >&2
  exit 1
fi

"$script_dir/verify-signed-repo.sh" "$tree" "$suite" "$tree/nelix-archive-keyring.gpg" >/dev/null

grep -Fxq \
  "deb [signed-by=/usr/share/keyrings/nelix-archive-keyring.gpg] $base_url $suite $component" \
  "$tree/sources.list.https" || {
    echo "public APT sources.list.https does not match APT_PUBLIC_URL/suite/component" >&2
    exit 1
  }

grep -q '^Package: elpa-nelix$' "$tree/dists/$suite/$component/binary-$architecture/Packages"
gzip -dc "$tree/dists/$suite/$component/binary-$architecture/Packages.gz" |
  cmp -s - "$tree/dists/$suite/$component/binary-$architecture/Packages"

if [ -n "$expected_version" ]; then
  packages_version=$(awk '
    $1 == "Package:" && $2 == "elpa-nelix" { in_package = 1; next }
    in_package && $1 == "Version:" { print $2; exit }
    /^$/ { in_package = 0 }
  ' "$tree/dists/$suite/$component/binary-$architecture/Packages")
  if [ "$packages_version" != "$expected_version" ]; then
    echo "public APT Packages has stale elpa-nelix version: got=$packages_version expected=$expected_version" >&2
    exit 1
  fi
fi

deb_path=$(awk '$1 == "Filename:" { print $2; exit }' \
  "$tree/dists/$suite/$component/binary-$architecture/Packages")
if [ -z "$deb_path" ] || [ ! -f "$tree/$deb_path" ]; then
  echo "public APT tree is missing package payload referenced by Packages: $deb_path" >&2
  exit 1
fi

if [ -n "$expected_version" ]; then
  deb_version=$(dpkg-deb -f "$tree/$deb_path" Version)
  if [ "$deb_version" != "$expected_version" ]; then
    echo "public APT payload has stale elpa-nelix version: got=$deb_version expected=$expected_version" >&2
    exit 1
  fi
fi

verify_deb_payload "$tree/$deb_path"

printf 'nelix public apt tree verify ok: %s %s %s\n' "$tree" "$base_url" "$suite"
