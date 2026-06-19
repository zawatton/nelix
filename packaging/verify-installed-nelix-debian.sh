#!/bin/sh
set -eu

expected_version="${1:-0.1.0-4}"
expected_profile="${NELIX_EXPECTED_PROFILE:-$HOME/.local/state/nelix/profile}"
elpa_src_dir="/usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0"

if ! command -v dpkg-query >/dev/null 2>&1; then
  echo "dpkg-query not found; this verifier is for Debian-family packages" >&2
  exit 1
fi

installed_version="$(dpkg-query -W -f='${Version}' elpa-nelix 2>/dev/null || true)"
if [ -z "$installed_version" ]; then
  echo "elpa-nelix is not installed" >&2
  exit 1
fi

if ! dpkg --compare-versions "$installed_version" ge "$expected_version"; then
  echo "elpa-nelix is too old: installed=$installed_version expected>=$expected_version" >&2
  exit 1
fi

if [ ! -d "$elpa_src_dir" ]; then
  echo "ELPA source directory is missing: $elpa_src_dir" >&2
  exit 1
fi

for file in \
  /usr/bin/nelix \
  "$elpa_src_dir/nelix-cli.el" \
  "$elpa_src_dir/nelix-aot-manifest-engine.el" \
  "$elpa_src_dir/anvil-pkg-nelisp-smoke.el" \
  "$elpa_src_dir/anvil-pkg-nelisp-ert-shim.el"
do
  if [ ! -f "$file" ]; then
    echo "expected Debian payload file is missing: $file" >&2
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
(princ (format "nelix Debian install ok: version=%s profile=%s\n"
               (or (getenv "NELIX_INSTALLED_VERSION") "unknown")
               anvil-pkg-profile-dir))
'

export NELIX_EXPECTED_PROFILE="$expected_profile"
export NELIX_INSTALLED_VERSION="$installed_version"

emacs --batch --eval "(progn $check_forms)"

emacs -Q --batch \
  -L "$elpa_src_dir" \
  --eval "(progn $check_forms)"

cli_version="$(/usr/bin/nelix --json version)"
printf '%s\n' "$cli_version" | grep -q '"status":"ok"' || {
  echo "nelix CLI version did not report ok status: $cli_version" >&2
  exit 1
}
printf '%s\n' "$cli_version" | grep -q '"version":"0.1.0"' || {
  echo "nelix CLI version did not report expected upstream version: $cli_version" >&2
  exit 1
}

if [ -n "${NELIX_USER_MANIFEST:-}" ]; then
  if [ ! -f "$NELIX_USER_MANIFEST" ]; then
    echo "NELIX_USER_MANIFEST does not exist: $NELIX_USER_MANIFEST" >&2
    exit 1
  fi

  /usr/bin/nelix --json validate "$NELIX_USER_MANIFEST" >/dev/null
  /usr/bin/nelix --json lock "$NELIX_USER_MANIFEST" >/dev/null
  /usr/bin/nelix --json plan "$NELIX_USER_MANIFEST" >/dev/null
  /usr/bin/nelix --json apply "$NELIX_USER_MANIFEST" --dry-run >/dev/null

  if [ "${NELIX_USER_MANIFEST_NELISP:-0}" = 1 ]; then
    /usr/bin/nelix --runtime nelisp --json validate "$NELIX_USER_MANIFEST" >/dev/null
  fi
fi
