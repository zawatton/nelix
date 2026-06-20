#!/bin/sh
set -eu

image=${1:-debian:13-slim}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
dev_root=$(dirname "$repo")
repo_name=$(basename "$repo")
engine=${CONTAINER_ENGINE:-}

: "${NELISP_REPO_URL:=https://github.com/zawatton/nelisp.git}"
: "${NELISP_REF:=main}"

if [ -z "$engine" ]; then
  if command -v podman >/dev/null 2>&1; then
    engine=podman
  elif command -v docker >/dev/null 2>&1; then
    engine=docker
  else
    echo "podman or docker is required for the Debian no-Nix RC container gate" >&2
    exit 1
  fi
fi

"$engine" run --rm \
  -e "NELISP_REPO_URL=$NELISP_REPO_URL" \
  -e "NELISP_REF=$NELISP_REF" \
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
        echo "Debian no-Nix RC gate: nix command is present after $label" >&2
        exit 1
      fi
      if dpkg -s nix-bin >/dev/null 2>&1; then
        echo "Debian no-Nix RC gate: nix-bin is installed after $label" >&2
        exit 1
      fi
    }

    assert_no_nix start
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
    assert_no_nix build-deps

    git clone "$NELISP_REPO_URL" /opt/nelisp
    cd /opt/nelisp
    git checkout "$NELISP_REF"
    make standalone-reader
    test -x /opt/nelisp/target/nelisp
    /opt/nelisp/target/nelisp --eval "(+ 40 2)" | grep -qx "42"

    cd "/work/'"$repo_name"'"
    make deb-build DEB_BUILD_OPTIONS=nocheck
    test -f /work/elpa-nelix_0.1.0-5_all.deb
    apt-get install -y --no-install-recommends /work/elpa-nelix_0.1.0-5_all.deb
    assert_no_nix package-install

    fixture_home=/tmp/nelix-no-nix-rc-home
    check_home=/tmp/nelix-no-nix-rc-check-home
    audit_home=/tmp/nelix-no-nix-rc-audit-home
    mkdir -p "$fixture_home/.emacs.d/custom-lisp" "$fixture_home/Cowork/Notes/capture"
    mkdir -p "$check_home" "$audit_home"

    cat >"$fixture_home/.emacs.d/custom-lisp/nelix-linux.el" <<'"'"'EOF'"'"'
;;; nelix-linux.el --- no-Nix RC fixture -*- lexical-binding: t; -*-

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

    cat >"$fixture_home/.emacs.d/nelix-package.el" <<'"'"'EOF'"'"'
;;; nelix-package.el --- no-Nix RC fixture manifest -*- lexical-binding: t; -*-

(require '"'"'nelix)

(defvar nelix-linux-native-bootstrap-apt-packages)
(defvar nelix-linux-native-test-packages)

(defconst nelix-package-native-user-emacs-directory
  "/tmp/nelix-no-nix-rc-home/.emacs.d/")

(load (expand-file-name "custom-lisp/nelix-linux.el"
                        nelix-package-native-user-emacs-directory)
      nil nil t)

(nelix-environment
 (name "debian-no-nix-rc")
 (profile "native-test")
 (imports "custom-lisp/nelix-linux.el")
 (backend-policy
  (gnu/linux nelix-native)
  (darwin nelix-native)
  (windows-nt nelix-native))
 (linux-packages nelix-linux-native-test-packages)
 (bootstrap-apt-packages nelix-linux-native-bootstrap-apt-packages))

;;; nelix-package.el ends here
EOF

    cp "$fixture_home/.emacs.d/nelix-package.el" \
      "$fixture_home/.emacs.d/nelix-package-native.el"

    cat >"$fixture_home/.emacs.d/init.el" <<'"'"'EOF'"'"'
;;; init.el --- no-Nix RC fixture -*- lexical-binding: t; -*-

(add-to-list '"'"'load-path "/usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0")
(require '"'"'nelix)

(defun my-nelix-audit ()
  (nelix-audit-file "/tmp/nelix-no-nix-rc-home/.emacs.d/nelix-package.el"))

;;; init.el ends here
EOF

    : >"$fixture_home/.emacs.d/early-init.el"
    : >"$fixture_home/Cowork/Notes/capture/nelix-package-native.org"
    : >"$fixture_home/Cowork/Notes/capture/nelix-linux.org"

    common_env="HOME=$fixture_home \
      NELISP=/opt/nelisp/target/nelisp \
      NELISP_ROOT=/opt/nelisp \
      NELIX_USER_MANIFEST=$fixture_home/.emacs.d/nelix-package.el \
      NELIX_NATIVE_USER_MANIFEST=$fixture_home/.emacs.d/nelix-package-native.el \
      NELIX_NATIVE_USER_MANIFEST_ORG=$fixture_home/Cowork/Notes/capture/nelix-package-native.org \
      NELIX_NATIVE_LINUX_ORG=$fixture_home/Cowork/Notes/capture/nelix-linux.org \
      NELIX_USER_INIT=$fixture_home/.emacs.d/init.el \
      NELIX_USER_EARLY_INIT=$fixture_home/.emacs.d/early-init.el \
      NELIX_USER_MANIFEST_LABEL=no-nix-rc \
      NELIX_RC_CHECK_HOME=$check_home \
      NELIX_RC_AUDIT_HOME=$audit_home \
      NELIX_USER_MANIFEST_NELISP=skip \
      NELIX_USER_MANIFEST_LOCKED=skip \
      NELIX_USER_MANIFEST_MIN_TARGETS=6 \
      NELIX_USER_MANIFEST_MAX_MISSING=6 \
      NELIX_USER_MANIFEST_MAX_EXTRA=6 \
      NELIX_USER_MANIFEST_MAX_REMOVE=6 \
      NELIX_INIT_MIGRATION_AUDIT=load-only \
      NELIX_INIT_MIGRATION_REQUIRE_DEB=skip \
      NELIX_INIT_MIGRATION_MIN_TARGETS=6 \
      NELIX_INIT_MIGRATION_MAX_MISSING=6 \
      NELIX_INIT_MIGRATION_MAX_EXTRA=6 \
      NELIX_INIT_MIGRATION_MAX_REMOVE=6 \
      NELIX_SOURCE_NELISP_TRANSACTION_STRICT=0"

    env $common_env make nelix-rc-gate
    assert_no_nix rc-gate
    echo "Debian no-Nix RC container gate ok: image='"$image"' nelisp-ref=$NELISP_REF"
  '
