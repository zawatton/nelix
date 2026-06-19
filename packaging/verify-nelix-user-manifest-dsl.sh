#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
manifest="${NELIX_USER_MANIFEST:-$HOME/.emacs.d/nelix-package.el}"
nelisp_mode="${NELIX_USER_MANIFEST_NELISP:-auto}"
locked_mode="${NELIX_USER_MANIFEST_LOCKED:-auto}"

if [ ! -f "$manifest" ]; then
  echo "Nelix user manifest is missing: $manifest" >&2
  exit 1
fi

export NELIX_USER_MANIFEST="$manifest"

emacs -Q --batch \
  --eval '(let ((read-eval nil)
                (manifest (getenv "NELIX_USER_MANIFEST"))
                (environment-forms 0)
                (manifest-forms 0))
            (with-temp-buffer
              (insert-file-contents manifest)
              (goto-char (point-min))
              (condition-case nil
                  (while t
                    (let ((form (read (current-buffer))))
                      (when (and (consp form) (eq (car form) (quote nelix-environment)))
                        (setq environment-forms (1+ environment-forms)))
                      (when (and (consp form) (eq (car form) (quote nelix-manifest)))
                        (setq manifest-forms (1+ manifest-forms)))))
                (end-of-file nil)))
            (unless (= environment-forms 1)
              (error "Nelix user manifest must contain exactly one top-level nelix-environment form, got %S"
                     environment-forms))
            (unless (= manifest-forms 0)
              (error "Nelix user manifest must use DSL v1, not top-level nelix-manifest"))
            (princ "nelix user manifest DSL v1 ok\n"))'

NELIX_LISPDIR="$repo_dir" "$repo_dir/bin/nelix" --json validate "$manifest" >/dev/null

run_nelisp_validate() {
  NELIX_LISPDIR="$repo_dir" "$repo_dir/bin/nelix" \
    --runtime nelisp --json validate "$manifest" >/dev/null
}

run_nelix_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${NELIX_USER_MANIFEST_NELISP_TIMEOUT:-30s}" \
      env NELIX_LISPDIR="$repo_dir" "$repo_dir/bin/nelix" "$@"
  else
    NELIX_LISPDIR="$repo_dir" "$repo_dir/bin/nelix" "$@"
  fi
}

expect_json_fragment() {
  label="$1"
  file="$2"
  fragment="$3"
  if ! grep -Fq "$fragment" "$file"; then
    echo "nelisp user manifest $label missing JSON fragment: $fragment" >&2
    sed -n '1,3p' "$file" >&2
    return 1
  fi
}

run_locked_readonly_checks() (
  locked_tmp="$(mktemp -d)"
  lock_file="$manifest.nelix-lock"
  backup="$locked_tmp/manifest.nelix-lock.backup"
  had_lock=0

  cleanup_locked() {
    if [ "$had_lock" -eq 1 ]; then
      cp -p "$backup" "$lock_file"
    else
      rm -f "$lock_file"
    fi
    rm -rf "$locked_tmp"
  }
  trap cleanup_locked EXIT HUP INT TERM

  if [ -f "$lock_file" ]; then
    cp -p "$lock_file" "$backup"
    had_lock=1
  fi

  if ! run_nelix_with_timeout --json lock "$manifest" \
    >"$locked_tmp/lock.json" \
    2>"$locked_tmp/lock.err"; then
    sed -n '1,3p' "$locked_tmp/lock.json" >&2
    sed -n '1,20p' "$locked_tmp/lock.err" >&2
    return 1
  fi
  expect_json_fragment lock "$locked_tmp/lock.json" '"schema":"nelix-lock"' || return 1
  expect_json_fragment lock "$locked_tmp/lock.json" '"schema-version":2' || return 1
  test -f "$lock_file" || {
    echo "nelix user manifest lock did not create lock file: $lock_file" >&2
    return 1
  }

  if ! run_nelix_with_timeout --json apply "$manifest" --locked --dry-run \
    >"$locked_tmp/locked-dry-run.json" \
    2>"$locked_tmp/locked-dry-run.err"; then
    sed -n '1,3p' "$locked_tmp/locked-dry-run.json" >&2
    sed -n '1,20p' "$locked_tmp/locked-dry-run.err" >&2
    return 1
  fi
  expect_json_fragment locked-dry-run "$locked_tmp/locked-dry-run.json" '"status":"dry-run"' || return 1
  expect_json_fragment locked-dry-run "$locked_tmp/locked-dry-run.json" '"locked":true' || return 1
  expect_json_fragment locked-dry-run "$locked_tmp/locked-dry-run.json" '"lock-enforced":true' || return 1
  expect_json_fragment locked-dry-run "$locked_tmp/locked-dry-run.json" '"lock-check":' || return 1

  case "$nelisp_mode" in
    1|true|yes|required)
      if ! run_nelix_with_timeout --runtime nelisp --json apply "$manifest" --locked --dry-run \
        >"$locked_tmp/nelisp-locked-dry-run.json" \
        2>"$locked_tmp/nelisp-locked-dry-run.err"; then
        sed -n '1,3p' "$locked_tmp/nelisp-locked-dry-run.json" >&2
        sed -n '1,20p' "$locked_tmp/nelisp-locked-dry-run.err" >&2
        return 1
      fi
      expect_json_fragment nelisp-locked-dry-run "$locked_tmp/nelisp-locked-dry-run.json" '"status":"dry-run"' || return 1
      expect_json_fragment nelisp-locked-dry-run "$locked_tmp/nelisp-locked-dry-run.json" '"locked":true' || return 1
      expect_json_fragment nelisp-locked-dry-run "$locked_tmp/nelisp-locked-dry-run.json" '"lock-enforced":true' || return 1
      expect_json_fragment nelisp-locked-dry-run "$locked_tmp/nelisp-locked-dry-run.json" '"fallback":":nelisp-aot-cache"' || return 1
      expect_json_fragment nelisp-locked-dry-run "$locked_tmp/nelisp-locked-dry-run.json" '"checked-by":":nelisp-aot-cache"' || return 1
      ;;
  esac

  printf 'nelix user manifest locked dry-run ok: %s\n' "$manifest"
)

run_nelisp_aot_readonly() {
  nelisp_tmp="$(mktemp -d)"
  trap 'rm -rf "$nelisp_tmp"' EXIT HUP INT TERM

  if ! run_nelix_with_timeout --runtime nelisp aot-cache "$manifest" \
    >"$nelisp_tmp/aot-cache.out" \
    2>"$nelisp_tmp/aot-cache.err"; then
    sed -n '1,20p' "$nelisp_tmp/aot-cache.out" >&2
    sed -n '1,20p' "$nelisp_tmp/aot-cache.err" >&2
    return 1
  fi
  if ! grep -Fq ':status ok' "$nelisp_tmp/aot-cache.out"; then
    echo "nelisp user manifest aot-cache did not report ok" >&2
    sed -n '1,20p' "$nelisp_tmp/aot-cache.out" >&2
    sed -n '1,20p' "$nelisp_tmp/aot-cache.err" >&2
    return 1
  fi

  if ! run_nelix_with_timeout --runtime nelisp --json list \
    >"$nelisp_tmp/list.json" \
    2>"$nelisp_tmp/list.err"; then
    sed -n '1,3p' "$nelisp_tmp/list.json" >&2
    sed -n '1,20p' "$nelisp_tmp/list.err" >&2
    return 1
  fi
  expect_json_fragment list "$nelisp_tmp/list.json" '[' || return 1

  if ! run_nelix_with_timeout --runtime nelisp --json audit "$manifest" \
    >"$nelisp_tmp/audit.json" \
    2>"$nelisp_tmp/audit.err"; then
    sed -n '1,3p' "$nelisp_tmp/audit.json" >&2
    sed -n '1,20p' "$nelisp_tmp/audit.err" >&2
    return 1
  fi
  expect_json_fragment audit "$nelisp_tmp/audit.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment audit "$nelisp_tmp/audit.json" '"backend":"nix"' || return 1

  if ! run_nelix_with_timeout --runtime nelisp --json plan "$manifest" --dry-run \
    >"$nelisp_tmp/plan.json" \
    2>"$nelisp_tmp/plan.err"; then
    sed -n '1,3p' "$nelisp_tmp/plan.json" >&2
    sed -n '1,20p' "$nelisp_tmp/plan.err" >&2
    return 1
  fi
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"status":"planned"' || return 1
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"backend":"nix"' || return 1

  if ! run_nelix_with_timeout --runtime nelisp --json apply "$manifest" --dry-run \
    >"$nelisp_tmp/apply-dry-run.json" \
    2>"$nelisp_tmp/apply-dry-run.err"; then
    sed -n '1,3p' "$nelisp_tmp/apply-dry-run.json" >&2
    sed -n '1,20p' "$nelisp_tmp/apply-dry-run.err" >&2
    return 1
  fi
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"status":"dry-run"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"backend":"nix"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"remove":[' || return 1

  if ! run_nelix_with_timeout --runtime nelisp --json upgrade-plan "$manifest" \
    >"$nelisp_tmp/upgrade-plan.json" \
    2>"$nelisp_tmp/upgrade-plan.err"; then
    sed -n '1,3p' "$nelisp_tmp/upgrade-plan.json" >&2
    sed -n '1,20p' "$nelisp_tmp/upgrade-plan.err" >&2
    return 1
  fi
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"operation":"upgrade"' || return 1
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"backend":"nix"' || return 1

  if ! run_nelix_with_timeout --runtime nelisp --json lock-check "$manifest" \
    >"$nelisp_tmp/lock-check.json" \
    2>"$nelisp_tmp/lock-check.err"; then
    sed -n '1,3p' "$nelisp_tmp/lock-check.json" >&2
    sed -n '1,20p' "$nelisp_tmp/lock-check.err" >&2
    return 1
  fi
  expect_json_fragment lock-check "$nelisp_tmp/lock-check.json" '"ok":true' || return 1
  expect_json_fragment lock-check "$nelisp_tmp/lock-check.json" '"checked-by":":nelisp-aot-cache"' || return 1

  rm -rf "$nelisp_tmp"
  trap - EXIT HUP INT TERM
  printf 'nelix user manifest nelisp AOT read-only ok: %s\n' "$manifest"
}

run_nelisp_runtime_checks() {
  run_nelisp_validate
  run_nelisp_aot_readonly
}

case "$nelisp_mode" in
  1|true|yes|required)
    run_nelisp_runtime_checks
    ;;
  0|false|no|skip)
    ;;
  auto)
    if command -v nelisp >/dev/null 2>&1 || [ -x "$repo_dir/../nelisp/target/nelisp" ]; then
      nelisp_log="$(mktemp)"
      if run_nelisp_runtime_checks 2>"$nelisp_log"; then
        rm -f "$nelisp_log"
      else
        rc=$?
        echo "nelisp user manifest runtime checks failed in auto mode; continuing because Emacs runtime validation passed (exit $rc)" >&2
        sed -n '1,20p' "$nelisp_log" >&2
        rm -f "$nelisp_log"
      fi
    else
      echo "nelisp not found; skipped --runtime nelisp user manifest validation" >&2
    fi
    ;;
  *)
    echo "invalid NELIX_USER_MANIFEST_NELISP value: $nelisp_mode" >&2
    exit 64
    ;;
esac

case "$locked_mode" in
  1|true|yes|required)
    run_locked_readonly_checks
    ;;
  0|false|no|skip)
    ;;
  auto)
    if command -v nix >/dev/null 2>&1; then
      locked_log="$(mktemp)"
      if run_locked_readonly_checks 2>"$locked_log"; then
        rm -f "$locked_log"
      else
        rc=$?
        echo "nelix user manifest locked dry-run checks failed in auto mode; continuing because normal validation passed (exit $rc)" >&2
        sed -n '1,20p' "$locked_log" >&2
        rm -f "$locked_log"
      fi
    else
      echo "nix not found; skipped user manifest locked dry-run validation" >&2
    fi
    ;;
  *)
    echo "invalid NELIX_USER_MANIFEST_LOCKED value: $locked_mode" >&2
    exit 64
    ;;
esac

printf 'nelix user manifest source-tree ok: %s\n' "$manifest"
