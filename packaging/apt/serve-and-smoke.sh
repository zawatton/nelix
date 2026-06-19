#!/bin/sh
set -eu

repo=${1:?usage: serve-and-smoke.sh REPO [SUITE] [EXPECTED_VERSION]}
suite=${2:-unstable}
expected_version=${3:-}
component=${NELIX_APT_COMPONENT:-main}
architecture=${NELIX_APT_ARCHITECTURE:-all}
release="$repo/dists/$suite/Release"
inrelease="$repo/dists/$suite/InRelease"
release_gpg="$repo/dists/$suite/Release.gpg"
keyring="$repo/nelix-archive-keyring.gpg"

for file in "$release" "$inrelease" "$release_gpg" "$keyring"; do
  if [ ! -f "$file" ]; then
    echo "missing HTTP smoke input: $file" >&2
    exit 1
  fi
done

if find "$repo" \( -name '.gnupg*' -o -name 'private-keys-v1.d' \) -print -quit | grep -q .; then
  echo "refusing to serve APT repository containing GPG test or secret material: $repo" >&2
  exit 1
fi

for tool in python3 apt-get gpgv dpkg-deb; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for the APT HTTP smoke" >&2
    exit 1
  fi
done

gpgv --keyring "$keyring" "$release_gpg" "$release" >/dev/null 2>&1
gpgv --keyring "$keyring" "$inrelease" >/dev/null 2>&1

tmp=$(mktemp -d)
server_pid=
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || :
    wait "$server_pid" >/dev/null 2>&1 || :
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

port_file="$tmp/port"
python3 - "$repo" "$port_file" <<'PY' &
import functools
import http.server
import sys

repo, port_file = sys.argv[1], sys.argv[2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=repo)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(port_file, "w", encoding="utf-8") as port:
    port.write(str(server.server_address[1]))
    port.write("\n")
    port.flush()
try:
    server.serve_forever()
finally:
    server.server_close()
PY
server_pid=$!

i=0
while [ ! -s "$port_file" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "HTTP server did not start" >&2
    exit 1
  fi
  sleep 0.05
done
port=$(cat "$port_file")

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
cp "$keyring" "$tmp/nelix-archive-keyring.gpg"
cat > "$tmp/sources.list" <<EOF
deb [arch=$architecture signed-by=$tmp/nelix-archive-keyring.gpg] http://127.0.0.1:$port $suite $component
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
  echo "APT HTTP smoke did not download elpa-nelix" >&2
  exit 1
fi

test "$(dpkg-deb -f "$downloaded" Package)" = "elpa-nelix"
test "$(dpkg-deb -f "$downloaded" Architecture)" = "all"
if [ -n "$expected_version" ]; then
  downloaded_version=$(dpkg-deb -f "$downloaded" Version)
  if [ "$downloaded_version" != "$expected_version" ]; then
    echo "APT HTTP smoke downloaded stale elpa-nelix version: got=$downloaded_version expected=$expected_version" >&2
    exit 1
  fi
fi

printf 'nelix apt http smoke ok: http://127.0.0.1:%s %s %s\n' "$port" "$suite" "$component"
