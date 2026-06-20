#!/bin/sh
set -eu

image=${1:-debian:12}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dev_root=$(dirname "$repo")
repo_name=$(basename "$repo")
engine=${CONTAINER_ENGINE:-}

: "${NELISP_REPO_URL:=https://github.com/zawatton/nelisp.git}"
: "${NELISP_REF:=main}"
: "${NELIX_REPO_URL:=https://github.com/zawatton/nelix.git}"
: "${NELIX_REF:=main}"
: "${NELIX_SOURCE:=local}"
: "${NELIX_NELISP_CONTAINER_STRICT:=0}"

if [ -z "$engine" ]; then
  if command -v podman >/dev/null 2>&1; then
    engine=podman
  elif command -v docker >/dev/null 2>&1; then
    engine=docker
  else
    echo "podman or docker is required for the NeLisp bootstrap container gate" >&2
    exit 1
  fi
fi

"$engine" run --rm \
  -e "NELISP_REPO_URL=$NELISP_REPO_URL" \
  -e "NELISP_REF=$NELISP_REF" \
  -e "NELIX_REPO_URL=$NELIX_REPO_URL" \
  -e "NELIX_REF=$NELIX_REF" \
  -e "NELIX_SOURCE=$NELIX_SOURCE" \
  -e "NELIX_REPO_NAME=$repo_name" \
  -e "NELIX_NELISP_CONTAINER_STRICT=$NELIX_NELISP_CONTAINER_STRICT" \
  -v "$dev_root:/work:rw" \
  -w /work \
  "$image" \
  /bin/sh -lc '
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    export HOME=/root

    apt-get update
    apt-get install -y --no-install-recommends \
      binutils \
      build-essential \
      ca-certificates \
      curl \
      debhelper \
      devscripts \
      dh-elpa \
      dpkg-dev \
      emacs-nox \
      fakeroot \
      file \
      findutils \
      gawk \
      git \
      grep \
      gzip \
      lintian \
      make \
      sed \
      tar

    git clone "$NELISP_REPO_URL" /opt/nelisp
    cd /opt/nelisp
    git checkout "$NELISP_REF"
    make standalone-reader
    test -x /opt/nelisp/target/nelisp
    /opt/nelisp/target/nelisp --eval "(+ 40 2)" | grep -qx "42"

    case "$NELIX_SOURCE" in
      local)
        nelix_work="/work/$NELIX_REPO_NAME"
        ;;
      clone)
        git clone "$NELIX_REPO_URL" /opt/nelix
        cd /opt/nelix
        git checkout "$NELIX_REF"
        nelix_work=/opt/nelix
        ;;
      *)
        echo "invalid NELIX_SOURCE: $NELIX_SOURCE" >&2
        exit 64
        ;;
    esac

    cd "$nelix_work"
    NELISP=/opt/nelisp/target/nelisp \
    NELISP_ROOT=/opt/nelisp \
      make smoke-nelisp smoke-nelix-nelisp smoke-nelix-cli-nelisp

    if [ "$NELIX_NELISP_CONTAINER_STRICT" = 1 ]; then
      NELISP=/opt/nelisp/target/nelisp \
      NELISP_ROOT=/opt/nelisp \
        make smoke-nelix-lock-plan-apply-nelisp
    fi

    make deb-build DEB_BUILD_OPTIONS=nocheck
    test -f /work/elpa-nelix_0.1.0-5_all.deb
    apt-get install -y --no-install-recommends /work/elpa-nelix_0.1.0-5_all.deb
    packaging/verify-installed-nelix-debian.sh 0.1.0-5

    if [ "$NELIX_NELISP_CONTAINER_STRICT" = 1 ]; then
      NELISP=/opt/nelisp/target/nelisp \
      NELISP_ROOT=/opt/nelisp \
        make verify-installed-cli-gate
    fi

    NELISP=/opt/nelisp/target/nelisp \
    NELISP_ROOT=/opt/nelisp \
    NELIX_RUNTIME=nelisp \
      /usr/bin/nelix --json version | grep -q "\"status\":\"ok\""

    echo "Nelix NeLisp bootstrap container gate ok: image='"$image"' nelisp-ref=$NELISP_REF nelix-source=$NELIX_SOURCE nelix-ref=$NELIX_REF strict=$NELIX_NELISP_CONTAINER_STRICT"
  '
