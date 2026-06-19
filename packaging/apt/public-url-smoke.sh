#!/bin/sh
set -eu

url=${1:?usage: public-url-smoke.sh PUBLIC_URL [SUITE] [EXPECTED_VERSION]}
suite=${2:-unstable}
expected_version=${3:-}
component=${NELIX_APT_COMPONENT:-main}
architecture=${NELIX_APT_ARCHITECTURE:-all}
keyring_source=${NELIX_APT_PUBLIC_KEYRING:-}

verify_deb_payload() {
  deb=$1
  dpkg-deb --fsys-tarfile "$deb" | tar -tf - |
    grep -Fxq './usr/bin/nelix' || {
      echo "public APT smoke payload is missing /usr/bin/nelix: $deb" >&2
      exit 1
    }
  for recipe in curl fd git jq ripgrep tree; do
    dpkg-deb --fsys-tarfile "$deb" | tar -tf - |
      grep -Fxq "./usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0/registry/packages/system/$recipe.el" || {
        echo "public APT smoke payload is missing packaged registry recipe: $recipe" >&2
        exit 1
      }
  done
  dpkg-deb --fsys-tarfile "$deb" |
    tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh |
    grep -Fq 'packaged_install native install ripgrep' || {
      echo "public APT smoke payload native CLI gate is missing packaged ripgrep install smoke" >&2
      exit 1
    }
  dpkg-deb --fsys-tarfile "$deb" |
    tar -xO ./usr/share/doc/elpa-nelix/packaging/verify-nelix-native-cli-gate.sh |
    grep -Fq 'native install fixture-archive --profile archive' || {
      echo "public APT smoke payload native CLI gate is missing archive install smoke" >&2
      exit 1
    }
}

url=${url%/}
case "$url" in
  *example.invalid*|"")
    echo "set APT_PUBLIC_URL to the real published APT repository URL" >&2
    exit 1
    ;;
  https://*) ;;
  http://*)
    if [ "${NELIX_ALLOW_INSECURE_PUBLIC_URL:-}" != 1 ]; then
      echo "refusing insecure public APT URL without NELIX_ALLOW_INSECURE_PUBLIC_URL=1: $url" >&2
      exit 1
    fi
    ;;
  *)
    echo "APT_PUBLIC_URL must be an http(s) repository URL, got: $url" >&2
    exit 1
    ;;
esac

for tool in apt-get curl dpkg-deb; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for the public APT URL smoke" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

mkdir -p \
  "$tmp/lists/partial" \
  "$tmp/cache/archives/partial" \
  "$tmp/sourceparts" \
  "$tmp/apt.conf.d" \
  "$tmp/preferences.d" \
  "$tmp/trusted.gpg.d" \
  "$tmp/download"
: > "$tmp/status"
: > "$tmp/apt.conf"
: > "$tmp/preferences"

keyring="$tmp/nelix-archive-keyring.gpg"
if [ -n "$keyring_source" ]; then
  cp "$keyring_source" "$keyring"
else
  curl -fsSL "$url/nelix-archive-keyring.gpg" -o "$keyring"
fi

cat > "$tmp/sources.list" <<EOF
deb [arch=$architecture signed-by=$keyring] $url $suite $component
EOF

apt_get() {
  apt-get \
    -o Dir::Etc::sourcelist="$tmp/sources.list" \
    -o Dir::Etc::sourceparts="$tmp/sourceparts" \
    -o Dir::Etc::main="$tmp/apt.conf" \
    -o Dir::Etc::parts="$tmp/apt.conf.d" \
    -o Dir::Etc::preferences="$tmp/preferences" \
    -o Dir::Etc::preferencesparts="$tmp/preferences.d" \
    -o Dir::Etc::trustedparts="$tmp/trusted.gpg.d" \
    -o Dir::State::lists="$tmp/lists" \
    -o Dir::State::status="$tmp/status" \
    -o Dir::Cache="$tmp/cache" \
    -o Dir::Cache::archives="$tmp/cache/archives" \
    -o Dir::Cache::pkgcache="$tmp/cache/pkgcache.bin" \
    -o Dir::Cache::srcpkgcache="$tmp/cache/srcpkgcache.bin" \
    -o APT::Default-Release= \
    -o Debug::NoLocking=1 \
    -o APT::Get::List-Cleanup=0 \
    "$@"
}

apt_get update >/dev/null
(
  cd "$tmp/download"
  apt_get download elpa-nelix >/dev/null
)

downloaded=$(find "$tmp/download" -maxdepth 1 -type f -name 'elpa-nelix_*_all.deb' -print -quit)
if [ -z "$downloaded" ]; then
  echo "public APT smoke did not download elpa-nelix from $url" >&2
  exit 1
fi

test "$(dpkg-deb -f "$downloaded" Package)" = "elpa-nelix"
test "$(dpkg-deb -f "$downloaded" Architecture)" = "all"
if [ -n "$expected_version" ]; then
  downloaded_version=$(dpkg-deb -f "$downloaded" Version)
  if [ "$downloaded_version" != "$expected_version" ]; then
    echo "public APT smoke downloaded stale elpa-nelix version: got=$downloaded_version expected=$expected_version" >&2
    exit 1
  fi
fi

verify_deb_payload "$downloaded"

printf 'nelix public apt smoke ok: %s %s %s\n' "$url" "$suite" "$component"
