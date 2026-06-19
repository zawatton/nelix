#!/bin/sh
set -eu

deb="${1:-../elpa-nelix_0.1.0-4_all.deb}"
expected_version="${2:-0.1.0-4}"
expected_profile="${NELIX_EXPECTED_PROFILE:-$HOME/.local/state/nelix/profile}"
elpa_rel="usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0"

if [ ! -f "$deb" ]; then
  echo "missing Debian package: $deb" >&2
  exit 1
fi

version="$(dpkg-deb -f "$deb" Version)"
if ! dpkg --compare-versions "$version" ge "$expected_version"; then
  echo "Debian package is too old: package=$version expected>=$expected_version" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
dpkg-deb -x "$deb" "$tmp"

elpa_src_dir="$tmp/$elpa_rel"
nelix_bin="$tmp/usr/bin/nelix"
packaging_dir="$tmp/usr/share/doc/elpa-nelix/packaging"

for file in \
  "$nelix_bin" \
  "$elpa_src_dir/nelix-cli.el" \
  "$elpa_src_dir/nelix-aot-manifest-engine.el" \
  "$elpa_src_dir/anvil-pkg-nelisp-smoke.el" \
  "$elpa_src_dir/anvil-pkg-nelisp-ert-shim.el" \
  "$packaging_dir/verify-nelix-aot-cache-gate.sh" \
  "$packaging_dir/verify-nelix-native-cli-gate.sh" \
  "$packaging_dir/verify-publication-urls.sh"
do
  if [ ! -f "$file" ]; then
    echo "expected extracted Debian payload file is missing: $file" >&2
    exit 1
  fi
done

check_forms='
(require (quote nelix))
(require (quote nelix-dsl))
(require (quote anvil-pkg))
(unless (fboundp (quote nelix-install))
  (error "nelix-install missing"))
(unless (macrop (symbol-function (quote nelix-define)))
  (error "nelix-define missing"))
(unless (string= (expand-file-name anvil-pkg-profile-dir)
                 (expand-file-name (getenv "NELIX_EXPECTED_PROFILE")))
  (error "unexpected profile: %S" anvil-pkg-profile-dir))
(unless (string= (anvil-pkg--nix-install-subcommand) "install")
  (error "unexpected nix profile subcommand"))
(princ (format "nelix extracted Debian load ok: version=%s profile=%s\n"
               (or (getenv "NELIX_EXTRACTED_VERSION") "unknown")
               anvil-pkg-profile-dir))
'

export NELIX_EXPECTED_PROFILE="$expected_profile"
export NELIX_EXTRACTED_VERSION="$version"

emacs -Q --batch \
  -L "$elpa_src_dir" \
  --eval "(progn $check_forms)"

NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --help >/dev/null
cli_version="$(NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --json version)"
printf '%s\n' "$cli_version" | grep -q '"status":"ok"' || {
  echo "extracted nelix CLI version did not report ok status: $cli_version" >&2
  exit 1
}
printf '%s\n' "$cli_version" | grep -q '"version":"0.1.0"' || {
  echo "extracted nelix CLI version did not report expected upstream version: $cli_version" >&2
  exit 1
}

NELIX_BIN="$nelix_bin" \
NELIX_LISPDIR="$elpa_src_dir" \
  bash "$packaging_dir/verify-nelix-native-cli-gate.sh" >/dev/null

NELIX_BIN="$nelix_bin" \
NELIX_LISPDIR="$elpa_src_dir" \
  bash "$packaging_dir/verify-nelix-aot-cache-gate.sh" >/dev/null

if [ -n "${NELIX_USER_MANIFEST:-}" ]; then
  if [ ! -f "$NELIX_USER_MANIFEST" ]; then
    echo "NELIX_USER_MANIFEST does not exist: $NELIX_USER_MANIFEST" >&2
    exit 1
  fi

  NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --json validate "$NELIX_USER_MANIFEST" >/dev/null
  NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --json lock "$NELIX_USER_MANIFEST" >/dev/null
  NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --json plan "$NELIX_USER_MANIFEST" >/dev/null
  NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" --json apply "$NELIX_USER_MANIFEST" --dry-run >/dev/null

  if [ "${NELIX_USER_MANIFEST_NELISP:-0}" = 1 ]; then
    NELIX_LISPDIR="$elpa_src_dir" "$nelix_bin" \
      --runtime nelisp --json validate "$NELIX_USER_MANIFEST" >/dev/null
  fi
fi
