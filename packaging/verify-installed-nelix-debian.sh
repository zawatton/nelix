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

  expect_json_fragment() {
    label="$1"
    file="$2"
    fragment="$3"
    if ! grep -Fq "$fragment" "$file"; then
      echo "nelix installed Debian $label output is missing: $fragment" >&2
      sed -n '1,5p' "$file" >&2
      return 1
    fi
  }

  run_nelisp_manifest_gate() (
    gate_tmp="$(mktemp -d)"
    lock_file="$NELIX_USER_MANIFEST.nelix-lock"
    cache_file="$NELIX_USER_MANIFEST.nelix-aot-targets"
    lock_backup="$gate_tmp/manifest.nelix-lock.backup"
    cache_backup="$gate_tmp/manifest.nelix-aot-targets.backup"
    had_lock=0
    had_cache=0

    cleanup_gate() {
      if [ "$had_lock" -eq 1 ]; then
        cp -p "$lock_backup" "$lock_file"
      else
        rm -f "$lock_file"
      fi
      if [ "$had_cache" -eq 1 ]; then
        cp -p "$cache_backup" "$cache_file"
      else
        rm -f "$cache_file"
      fi
      rm -rf "$gate_tmp"
    }
    trap cleanup_gate EXIT HUP INT TERM

    if [ -f "$lock_file" ]; then
      cp -p "$lock_file" "$lock_backup"
      had_lock=1
    fi
    if [ -f "$cache_file" ]; then
      cp -p "$cache_file" "$cache_backup"
      had_cache=1
    fi

    /usr/bin/nelix --json lock "$NELIX_USER_MANIFEST" >"$gate_tmp/lock.json"
    /usr/bin/nelix --runtime nelisp --json validate "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/validate.json"
    /usr/bin/nelix --runtime nelisp aot-cache "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/aot-cache.out"
    expect_json_fragment aot-cache "$gate_tmp/aot-cache.out" ':status ok'

    /usr/bin/nelix --runtime nelisp --json list >"$gate_tmp/list.json"
    expect_json_fragment list "$gate_tmp/list.json" '['

    /usr/bin/nelix --runtime nelisp --json audit "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/audit.json"
    expect_json_fragment audit "$gate_tmp/audit.json" '"fallback":":nelisp-aot-cache"'

    /usr/bin/nelix --runtime nelisp --json plan "$NELIX_USER_MANIFEST" --dry-run \
      >"$gate_tmp/plan.json"
    expect_json_fragment plan "$gate_tmp/plan.json" '"status":"planned"'
    expect_json_fragment plan "$gate_tmp/plan.json" '"fallback":":nelisp-aot-cache"'

    /usr/bin/nelix --runtime nelisp --json apply "$NELIX_USER_MANIFEST" --dry-run \
      >"$gate_tmp/apply-dry-run.json"
    expect_json_fragment apply-dry-run "$gate_tmp/apply-dry-run.json" '"status":"dry-run"'
    expect_json_fragment apply-dry-run "$gate_tmp/apply-dry-run.json" '"fallback":":nelisp-aot-cache"'

    /usr/bin/nelix --runtime nelisp --json upgrade-plan "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/upgrade-plan.json"
    expect_json_fragment upgrade-plan "$gate_tmp/upgrade-plan.json" '"operation":"upgrade"'
    expect_json_fragment upgrade-plan "$gate_tmp/upgrade-plan.json" '"fallback":":nelisp-aot-cache"'

    /usr/bin/nelix --runtime nelisp --json lock-check "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/lock-check.json"
    expect_json_fragment lock-check "$gate_tmp/lock-check.json" '"ok":true'
    expect_json_fragment lock-check "$gate_tmp/lock-check.json" '"checked-by":":nelisp-aot-cache"'

    case "${NELIX_USER_MANIFEST_LOCKED:-0}" in
      1|true|yes|required)
        /usr/bin/nelix --runtime nelisp --json apply "$NELIX_USER_MANIFEST" --locked --dry-run \
          >"$gate_tmp/locked-apply-dry-run.json"
        expect_json_fragment locked-apply-dry-run "$gate_tmp/locked-apply-dry-run.json" '"locked":true'
        expect_json_fragment locked-apply-dry-run "$gate_tmp/locked-apply-dry-run.json" '"checked-by":":nelisp-aot-cache"'
        ;;
    esac
  )

  (
    lock_tmp="$(mktemp -d)"
    lock_file="$NELIX_USER_MANIFEST.nelix-lock"
    lock_backup="$lock_tmp/manifest.nelix-lock.backup"
    had_lock=0

    cleanup_lock() {
      if [ "$had_lock" -eq 1 ]; then
        cp -p "$lock_backup" "$lock_file"
      else
        rm -f "$lock_file"
      fi
      rm -rf "$lock_tmp"
    }
    trap cleanup_lock EXIT HUP INT TERM

    if [ -f "$lock_file" ]; then
      cp -p "$lock_file" "$lock_backup"
      had_lock=1
    fi

    /usr/bin/nelix --json validate "$NELIX_USER_MANIFEST" >/dev/null
    /usr/bin/nelix --json lock "$NELIX_USER_MANIFEST" >/dev/null
    /usr/bin/nelix --json plan "$NELIX_USER_MANIFEST" >/dev/null
    /usr/bin/nelix --json apply "$NELIX_USER_MANIFEST" --dry-run >/dev/null

    case "${NELIX_USER_MANIFEST_LOCKED:-0}" in
      1|true|yes|required)
        /usr/bin/nelix --json apply "$NELIX_USER_MANIFEST" --locked --dry-run >/dev/null
        ;;
      0|false|no|skip)
        ;;
      *)
        echo "invalid NELIX_USER_MANIFEST_LOCKED value: ${NELIX_USER_MANIFEST_LOCKED}" >&2
        exit 64
        ;;
    esac
  )

  case "${NELIX_USER_MANIFEST_NELISP:-0}" in
    1|true|yes|required)
      run_nelisp_manifest_gate
      ;;
    0|false|no|skip)
      ;;
    *)
      echo "invalid NELIX_USER_MANIFEST_NELISP value: ${NELIX_USER_MANIFEST_NELISP}" >&2
      exit 64
      ;;
  esac
fi
