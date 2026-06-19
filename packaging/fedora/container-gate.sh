#!/bin/sh
set -eu

image=${1:-fedora:latest}
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
engine=${CONTAINER_ENGINE:-}

if [ -z "$engine" ]; then
  if command -v podman >/dev/null 2>&1; then
    engine=podman
  elif command -v docker >/dev/null 2>&1; then
    engine=docker
  else
    echo "podman or docker is required for Fedora container gate" >&2
    exit 1
  fi
fi

"$engine" run --rm \
  -v "$root:/work:rw" \
  -w /work \
  "$image" \
  /bin/sh -lc '
    set -eu
    dnf -y install rpm-build rpmlint createrepo_c emacs make git curl ca-certificates gzip tar findutils
    make fedora-local-gate FEDORA_TOPDIR=/tmp/nelix-rpmbuild FEDORA_REPO_DIR=/tmp/nelix-rpm-repo
  '
