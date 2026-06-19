#!/bin/sh
set -eu

usage() {
  echo "usage: verify-publication-urls.sh APT_PUBLIC_URL FEDORA_PUBLIC_URL" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  exit 64
fi

apt_url=${1%/}
fedora_url=${2%/}

check_url() {
  name=$1
  url=$2
  case "$url" in
    *example.invalid*|"")
      echo "set $name to the real published repository URL" >&2
      exit 1
      ;;
    https://*) ;;
    http://*)
      if [ "${NELIX_ALLOW_INSECURE_PUBLIC_URL:-}" != 1 ]; then
        echo "refusing insecure $name without NELIX_ALLOW_INSECURE_PUBLIC_URL=1: $url" >&2
        exit 1
      fi
      ;;
    *)
      echo "$name must be an http(s) repository URL, got: $url" >&2
      exit 1
      ;;
  esac
}

check_url APT_PUBLIC_URL "$apt_url"
check_url FEDORA_PUBLIC_URL "$fedora_url"

printf 'nelix publication urls ok: apt=%s fedora=%s\n' "$apt_url" "$fedora_url"
