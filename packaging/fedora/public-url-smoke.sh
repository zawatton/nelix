#!/bin/sh
set -eu

url=${1:?usage: public-url-smoke.sh PUBLIC_URL [EXPECTED_VERSION]}
expected_version=${2:-}
url=${url%/}

case "$url" in
  *example.invalid*|"")
    echo "set FEDORA_PUBLIC_URL to the real published Fedora repository URL" >&2
    exit 1
    ;;
  https://*) ;;
  http://*)
    if [ "${NELIX_ALLOW_INSECURE_PUBLIC_URL:-}" != 1 ]; then
      echo "refusing insecure public Fedora URL without NELIX_ALLOW_INSECURE_PUBLIC_URL=1: $url" >&2
      exit 1
    fi
    ;;
  *)
    echo "FEDORA_PUBLIC_URL must be an http(s) repository URL, got: $url" >&2
    exit 1
    ;;
esac

if [ "$(id -u)" != 0 ]; then
  echo "public Fedora URL smoke installs packages; run as root or inside a disposable Fedora container" >&2
  exit 1
fi

for tool in dnf rpm emacs nelix; do
  if [ "$tool" = nelix ]; then
    continue
  fi
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required for the public Fedora URL smoke" >&2
    exit 1
  fi
done

repo_gpgcheck=${NELIX_FEDORA_REPO_GPGCHECK:-0}
gpgcheck=${NELIX_FEDORA_GPGCHECK:-0}
gpgkey_url=${NELIX_FEDORA_GPGKEY_URL:-}

set -- \
  -y \
  --disablerepo='*' \
  --repofrompath=nelix-public,"$url" \
  --setopt=nelix-public.gpgcheck="$gpgcheck" \
  --setopt=nelix-public.repo_gpgcheck="$repo_gpgcheck" \
  --enablerepo=nelix-public
if [ -n "$gpgkey_url" ]; then
  set -- "$@" --setopt=nelix-public.gpgkey="$gpgkey_url"
fi
dnf "$@" install nelix emacs-nelix

rpm -q nelix emacs-nelix
if [ -n "$expected_version" ]; then
  test "$(rpm -q --qf '%{VERSION}' nelix)" = "$expected_version"
  test "$(rpm -q --qf '%{VERSION}' emacs-nelix)" = "$expected_version"
fi
emacs -Q --batch -L /usr/share/emacs/site-lisp/nelix \
  --eval "(require 'nelix)" \
  --eval "(require 'nelix-dsl)" \
  --eval "(message \"nelix public Fedora load smoke ok\")"
nelix --help >/dev/null

printf 'nelix public fedora smoke ok: %s\n' "$url"
