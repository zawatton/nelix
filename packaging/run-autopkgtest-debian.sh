#!/bin/sh
# Run the local Debian autopkgtest gate.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: run-autopkgtest-debian.sh DEB TREE" >&2
  exit 64
fi

deb="$1"
tree="$2"
autopkgtest_cmd="${AUTOPKGTEST:-autopkgtest}"
sudo_cmd="${SUDO-sudo}"
log="$(mktemp)"

cleanup() {
  rm -f "$log"
}
trap cleanup EXIT HUP INT TERM

set +e
if [ "$(id -u)" = 0 ] || [ -z "$sudo_cmd" ]; then
  "$autopkgtest_cmd" "$deb" "$tree" -- null >"$log" 2>&1
else
  "$sudo_cmd" "$autopkgtest_cmd" "$deb" "$tree" -- null >"$log" 2>&1
fi
rc=$?
set -e

cat "$log"

case "$rc" in
  0)
    exit 0
    ;;
  8)
    if grep -Eq '^[[:space:]]*load[[:space:]]+PASS([[:space:]]|$)' "$log" &&
       ! grep -Eq '^[[:space:]]*load[[:space:]]+FAIL([[:space:]]|$)' "$log"; then
      echo "autopkgtest returned 8 after load PASS; accepting known null-backend status" >&2
      exit 0
    fi
    exit "$rc"
    ;;
  *)
    exit "$rc"
    ;;
esac
