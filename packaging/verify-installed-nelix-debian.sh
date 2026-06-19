#!/bin/sh
set -eu

expected_version="${1:-0.1.0-5}"
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

  json_array_count() {
    file="$1"
    key="$2"
    emacs -Q --batch \
      --eval '(require (quote json))' \
      --eval '(let* ((json-object-type (quote alist))
                     (json-array-type (quote list))
                     (json-key-type (quote string))
                     (_ (when (equal (car command-line-args-left) "--")
                          (pop command-line-args-left)))
                     (file (pop command-line-args-left))
                     (key (pop command-line-args-left))
                     (obj (json-read-file file))
                     (rows (alist-get key obj nil nil (function string=))))
                (princ (length rows)))' \
      -- "$file" "$key"
  }

  json_top_level_count() {
    file="$1"
    emacs -Q --batch \
      --eval '(require (quote json))' \
      --eval '(let* ((json-object-type (quote alist))
                     (json-array-type (quote list))
                     (json-key-type (quote string))
                     (_ (when (equal (car command-line-args-left) "--")
                          (pop command-line-args-left)))
                     (file (pop command-line-args-left))
                     (obj (json-read-file file)))
                (princ (length (if (vectorp obj) (append obj nil) obj))))' \
      -- "$file"
  }

  report_top_level_count() {
    label="$1"
    file="$2"
    count="$(json_top_level_count "$file")" || return 1
    printf 'nelix installed Debian %s-count: %s\n' "$label" "$count" >&2
  }

  report_json_counts() {
    label="$1"
    file="$2"
    shift 2
    printf 'nelix installed Debian %s-counts:' "$label" >&2
    for key in "$@"; do
      count="$(json_array_count "$file" "$key")" || return 1
      printf ' %s=%s' "$key" "$count" >&2
    done
    printf '\n' >&2
  }

  check_aot_target_count() {
    cache_file="$1"
    min_targets="${NELIX_USER_MANIFEST_MIN_TARGETS:-0}"
    target_count="$(
      grep -c '^target-id[[:space:]]' "$cache_file" 2>/dev/null ||
        printf '0\n'
    )"
    printf 'nelix installed Debian target-count: %s min=%s\n' \
      "$target_count" "$min_targets" >&2
    case "$min_targets" in
      ''|*[!0-9]*)
        echo "invalid NELIX_USER_MANIFEST_MIN_TARGETS value: $min_targets" >&2
        return 64
        ;;
    esac
    if [ "$min_targets" -gt 0 ] && [ "$target_count" -lt "$min_targets" ]; then
      echo "nelix installed Debian target count $target_count is below NELIX_USER_MANIFEST_MIN_TARGETS=$min_targets" >&2
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
    check_aot_target_count "$cache_file"

    /usr/bin/nelix --runtime nelisp --json list >"$gate_tmp/list.json"
    expect_json_fragment list "$gate_tmp/list.json" '['
    report_top_level_count list "$gate_tmp/list.json"

    /usr/bin/nelix --runtime nelisp --json audit "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/audit.json"
    expect_json_fragment audit "$gate_tmp/audit.json" '"fallback":":nelisp-aot-cache"'
    report_json_counts audit "$gate_tmp/audit.json" present missing extra

    /usr/bin/nelix --runtime nelisp --json plan "$NELIX_USER_MANIFEST" --dry-run \
      >"$gate_tmp/plan.json"
    expect_json_fragment plan "$gate_tmp/plan.json" '"status":"planned"'
    expect_json_fragment plan "$gate_tmp/plan.json" '"fallback":":nelisp-aot-cache"'
    report_json_counts plan "$gate_tmp/plan.json" install remove keep protected commands

    /usr/bin/nelix --runtime nelisp --json apply "$NELIX_USER_MANIFEST" --dry-run \
      >"$gate_tmp/apply-dry-run.json"
    expect_json_fragment apply-dry-run "$gate_tmp/apply-dry-run.json" '"status":"dry-run"'
    expect_json_fragment apply-dry-run "$gate_tmp/apply-dry-run.json" '"fallback":":nelisp-aot-cache"'
    report_json_counts apply-dry-run "$gate_tmp/apply-dry-run.json" install remove keep protected commands

    /usr/bin/nelix --runtime nelisp --json upgrade-plan "$NELIX_USER_MANIFEST" \
      >"$gate_tmp/upgrade-plan.json"
    expect_json_fragment upgrade-plan "$gate_tmp/upgrade-plan.json" '"operation":"upgrade"'
    expect_json_fragment upgrade-plan "$gate_tmp/upgrade-plan.json" '"fallback":":nelisp-aot-cache"'
    report_json_counts upgrade-plan "$gate_tmp/upgrade-plan.json" upgrade pinned missing

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
