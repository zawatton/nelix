#!/bin/sh
set -eu

image=${1:-debian:12}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dev_root=$(dirname "$repo")
repo_name=$(basename "$repo")
engine=${CONTAINER_ENGINE:-}

if [ -z "$engine" ]; then
  if command -v podman >/dev/null 2>&1; then
    engine=podman
  elif command -v docker >/dev/null 2>&1; then
    engine=docker
  else
    echo "podman or docker is required for the Debian no-Nix container gate" >&2
    exit 1
  fi
fi

"$engine" run --rm \
  -v "$dev_root:/work:rw" \
  -w "/work/$repo_name" \
  "$image" \
  /bin/sh -lc '
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    export HOME=/root

    assert_no_nix() {
      label=$1
      if command -v nix >/dev/null 2>&1; then
        echo "Debian no-Nix gate: nix command is present after $label" >&2
        exit 1
      fi
      if dpkg -s nix-bin >/dev/null 2>&1; then
        echo "Debian no-Nix gate: nix-bin is installed after $label" >&2
        exit 1
      fi
    }

    assert_no_nix start
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates \
      build-essential \
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
    assert_no_nix build-deps

    make deb-build DEB_BUILD_OPTIONS=nocheck
    test -f /work/elpa-nelix_0.1.0-5_all.deb
    apt-get install -y --no-install-recommends /work/elpa-nelix_0.1.0-5_all.deb
    assert_no_nix package-install
    packaging/verify-installed-nelix-debian.sh 0.1.0-5

    native_home=/tmp/nelix-no-nix-home
    mkdir -p "$native_home/.emacs.d/custom-lisp" "$native_home/Cowork/Notes/capture"
    cat >"$native_home/.emacs.d/custom-lisp/nelix-linux.el" <<'"'"'EOF'"'"'
;;; nelix-linux.el --- no-Nix container native test fixture -*- lexical-binding: t; -*-

(require '"'"'nelix)

(defconst nelix-linux-native-bootstrap-apt-packages
  '"'"'(emacs elpa-nelix))

(defconst nelix-linux-native-test-packages
  '"'"'("git" "curl" "ripgrep" "fd" "jq" "tree"))

(defconst nelix-linux-native-fallback-packages
  '"'"'("cacert" "gcc" "gnumake" "pkg-config"
    "dpkg" "fakeroot" "debian-devscripts"
    "nelix-system-debhelper" "nelix-system-dh-elpa"
    "nelix-system-lintian" "nelix-system-autopkgtest"))

(provide '"'"'nelix-linux)
;;; nelix-linux.el ends here
EOF

    cat >"$native_home/.emacs.d/nelix-package-native.el" <<'"'"'EOF'"'"'
;;; nelix-package-native.el --- no-Nix container native manifest -*- lexical-binding: t; -*-

(require '"'"'nelix)

(defvar nelix-linux-native-bootstrap-apt-packages)
(defvar nelix-linux-native-test-packages)

(defconst nelix-package-native-user-emacs-directory
  "/tmp/nelix-no-nix-home/.emacs.d/")

(load (expand-file-name "custom-lisp/nelix-linux.el"
                        nelix-package-native-user-emacs-directory)
      nil nil t)

(nelix-environment
 (name "debian-no-nix-native")
 (profile "native-test")
 (imports "custom-lisp/nelix-linux.el")
 (backend-policy
  (gnu/linux nelix-native)
  (darwin nelix-native)
  (windows-nt nelix-native))
 (linux-packages nelix-linux-native-test-packages)
 (bootstrap-apt-packages nelix-linux-native-bootstrap-apt-packages))

;;; nelix-package-native.el ends here
EOF

    : >"$native_home/Cowork/Notes/capture/nelix-package-native.org"
    : >"$native_home/Cowork/Notes/capture/nelix-linux.org"

    HOME="$native_home" \
    NELIX_NATIVE_USER_MANIFEST="$native_home/.emacs.d/nelix-package-native.el" \
    NELIX_NATIVE_USER_MANIFEST_ORG="$native_home/Cowork/Notes/capture/nelix-package-native.org" \
    NELIX_NATIVE_LINUX_ORG="$native_home/Cowork/Notes/capture/nelix-linux.org" \
    NELIX_BIN=/usr/bin/nelix \
    NELIX_LISPDIR=/usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0 \
      packaging/verify-nelix-native-user-gate.sh

    assert_no_nix native-gate
    echo "Debian no-Nix container gate ok: image='"$image"'"
  '
