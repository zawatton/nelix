#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
manifest="${NELIX_USER_MANIFEST:-$HOME/.emacs.d/nelix-package.el}"
verification_label="${NELIX_USER_MANIFEST_LABEL:-source-tree}"
nelisp_mode="${NELIX_USER_MANIFEST_NELISP:-auto}"
locked_mode="${NELIX_USER_MANIFEST_LOCKED:-auto}"
nelisp_max_seconds="${NELIX_USER_MANIFEST_NELISP_MAX_SECONDS:-5}"
nelisp_min_targets="${NELIX_USER_MANIFEST_MIN_TARGETS:-0}"
nelisp_max_remove="${NELIX_USER_MANIFEST_MAX_REMOVE:-}"
nelisp_max_missing="${NELIX_USER_MANIFEST_MAX_MISSING:-}"
nelisp_max_extra="${NELIX_USER_MANIFEST_MAX_EXTRA:-}"

if [ ! -f "$manifest" ]; then
  echo "Nelix user manifest is missing: $manifest" >&2
  exit 1
fi

export NELIX_USER_MANIFEST="$manifest"

if [ -n "${NELIX_BIN:-}" ]; then
  nelix_bin="$NELIX_BIN"
elif [ -x "$repo_dir/bin/nelix" ]; then
  nelix_bin="$repo_dir/bin/nelix"
elif [ -x /usr/bin/nelix ]; then
  nelix_bin=/usr/bin/nelix
else
  nelix_bin=nelix
fi

if [ -n "${NELIX_LISPDIR:-}" ]; then
  nelix_lispdir="$NELIX_LISPDIR"
elif [ -f "$repo_dir/nelix.el" ]; then
  nelix_lispdir="$repo_dir"
elif [ -d /usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0 ]; then
  nelix_lispdir=/usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0
else
  nelix_lispdir="$repo_dir"
fi

case "$nelisp_max_seconds" in
  ''|*[!0-9]*)
    echo "invalid NELIX_USER_MANIFEST_NELISP_MAX_SECONDS value: $nelisp_max_seconds" >&2
    exit 64
    ;;
esac

case "$nelisp_min_targets" in
  ''|*[!0-9]*)
    echo "invalid NELIX_USER_MANIFEST_MIN_TARGETS value: $nelisp_min_targets" >&2
    exit 64
    ;;
esac

case "$nelisp_max_remove" in
  ''|*[!0-9]*)
    if [ -n "$nelisp_max_remove" ]; then
      echo "invalid NELIX_USER_MANIFEST_MAX_REMOVE value: $nelisp_max_remove" >&2
      exit 64
    fi
    ;;
esac

case "$nelisp_max_missing" in
  ''|*[!0-9]*)
    if [ -n "$nelisp_max_missing" ]; then
      echo "invalid NELIX_USER_MANIFEST_MAX_MISSING value: $nelisp_max_missing" >&2
      exit 64
    fi
    ;;
esac

case "$nelisp_max_extra" in
  ''|*[!0-9]*)
    if [ -n "$nelisp_max_extra" ]; then
      echo "invalid NELIX_USER_MANIFEST_MAX_EXTRA value: $nelisp_max_extra" >&2
      exit 64
    fi
    ;;
esac

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

NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" --json validate "$manifest" >/dev/null

run_nelisp_validate() {
  NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" \
    --runtime nelisp --json validate "$manifest" >/dev/null
}

run_nelix_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${NELIX_USER_MANIFEST_NELISP_TIMEOUT:-30s}" \
      env NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" "$@"
  else
    NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" "$@"
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

compare_runtime_json() {
  label="$1"
  emacs_json="$2"
  nelisp_json="$3"
  shift 3
  emacs -Q --batch \
    -l "$repo_dir/packaging/compare-nelix-json.el" \
    -- "$label" "$emacs_json" "$nelisp_json" "$@"
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

json_array_names() {
  file="$1"
  key="$2"
  emacs -Q --batch \
    --eval '(require (quote json))' \
    --eval '(require (quote subr-x))' \
    --eval '(let* ((json-object-type (quote alist))
                   (json-array-type (quote list))
                   (json-key-type (quote string))
                   (_ (when (equal (car command-line-args-left) "--")
                        (pop command-line-args-left)))
                   (file (pop command-line-args-left))
                   (key (pop command-line-args-left))
                   (obj (json-read-file file))
                   (rows (alist-get key obj nil nil (function string=))))
              (princ
               (string-join
                (mapcar
                 (lambda (row)
                   (cond
                    ((stringp row) row)
                    ((let ((name (and (listp row)
                                      (alist-get "name" row nil nil (function string=)))))
                       (and name (format "%s" name))))
                    (t (format "%S" row))))
                 rows)
                ",")))' \
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
  printf 'nelix user manifest %s-count: %s\n' "$label" "$count" >&2
}

report_json_counts() {
  label="$1"
  file="$2"
  shift 2
  printf 'nelix user manifest %s-counts:' "$label" >&2
  for key in "$@"; do
    count="$(json_array_count "$file" "$key")" || return 1
    printf ' %s=%s' "$key" "$count" >&2
  done
  printf '\n' >&2
}

check_profile_diff_candidates() {
  file="$1"
  key="$2"
  limit="$3"
  count="$(json_array_count "$file" "$key")" || return 1
  names="$(json_array_names "$file" "$key")" || return 1
  printf 'nelix user manifest audit-%s-count: %s max=%s names=%s\n' \
    "$key" "$count" "${limit:-none}" "${names:-none}" >&2
  if [ -n "$limit" ] && [ "$count" -gt "$limit" ]; then
    echo "nelix user manifest audit $key count $count exceeds limit $limit" >&2
    return 1
  fi
}

check_remove_candidates() {
  file="$1"
  remove_count="$(json_array_count "$file" remove)" || return 1
  remove_names="$(json_array_names "$file" remove)" || return 1
  printf 'nelix user manifest remove-count: %s max=%s names=%s\n' \
    "$remove_count" "${nelisp_max_remove:-none}" "${remove_names:-none}" >&2
  if [ -n "$nelisp_max_remove" ] && [ "$remove_count" -gt "$nelisp_max_remove" ]; then
    echo "nelix user manifest remove count $remove_count exceeds NELIX_USER_MANIFEST_MAX_REMOVE=$nelisp_max_remove" >&2
    return 1
  fi
}

now_millis() {
  date +%s%3N
}

run_nelix_timed() {
  label="$1"
  out_file="$2"
  err_file="$3"
  shift 3
  start="$(now_millis)"
  if run_nelix_with_timeout "$@" >"$out_file" 2>"$err_file"; then
    rc=0
  else
    rc=$?
  fi
  end="$(now_millis)"
  elapsed_ms=$((end - start))
  elapsed=$((elapsed_ms / 1000))
  max_ms=$((nelisp_max_seconds * 1000))
  printf 'nelix user manifest timing: %s elapsed-ms=%s elapsed=%ss max=%ss\n' \
    "$label" "$elapsed_ms" "$elapsed" "$nelisp_max_seconds" >&2
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$nelisp_max_seconds" -gt 0 ] && [ "$elapsed_ms" -gt "$max_ms" ]; then
    echo "nelix user manifest $label exceeded NELIX_USER_MANIFEST_NELISP_MAX_SECONDS=${nelisp_max_seconds}s" >&2
    return 1
  fi
  return 0
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

  if ! run_nelix_timed aot-cache "$nelisp_tmp/aot-cache.out" "$nelisp_tmp/aot-cache.err" \
    --runtime nelisp aot-cache "$manifest"; then
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
  target_count="$(
    grep -c '^target-id[[:space:]]' "$manifest.nelix-aot-targets" 2>/dev/null ||
      printf '0\n'
  )"
  printf 'nelix user manifest target-count: %s min=%s\n' \
    "$target_count" "$nelisp_min_targets" >&2
  if [ "$nelisp_min_targets" -gt 0 ] && [ "$target_count" -lt "$nelisp_min_targets" ]; then
    echo "nelix user manifest target count $target_count is below NELIX_USER_MANIFEST_MIN_TARGETS=$nelisp_min_targets" >&2
    return 1
  fi

  if ! run_nelix_timed list "$nelisp_tmp/list.json" "$nelisp_tmp/list.err" \
    --runtime nelisp --json list; then
    sed -n '1,3p' "$nelisp_tmp/list.json" >&2
    sed -n '1,20p' "$nelisp_tmp/list.err" >&2
    return 1
  fi
  expect_json_fragment list "$nelisp_tmp/list.json" '[' || return 1
  report_top_level_count list "$nelisp_tmp/list.json" || return 1
  if ! run_nelix_with_timeout --json list \
    >"$nelisp_tmp/list-emacs.json" \
    2>"$nelisp_tmp/list-emacs.err"; then
    sed -n '1,3p' "$nelisp_tmp/list-emacs.json" >&2
    sed -n '1,20p' "$nelisp_tmp/list-emacs.err" >&2
    return 1
  fi
  compare_runtime_json list "$nelisp_tmp/list-emacs.json" "$nelisp_tmp/list.json" "." || return 1

  if ! run_nelix_timed audit "$nelisp_tmp/audit.json" "$nelisp_tmp/audit.err" \
    --runtime nelisp --json audit "$manifest"; then
    sed -n '1,3p' "$nelisp_tmp/audit.json" >&2
    sed -n '1,20p' "$nelisp_tmp/audit.err" >&2
    return 1
  fi
  expect_json_fragment audit "$nelisp_tmp/audit.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment audit "$nelisp_tmp/audit.json" '"backend":"nix"' || return 1
  if ! run_nelix_with_timeout --json audit "$manifest" \
    >"$nelisp_tmp/audit-emacs.json" \
    2>"$nelisp_tmp/audit-emacs.err"; then
    sed -n '1,3p' "$nelisp_tmp/audit-emacs.json" >&2
    sed -n '1,20p' "$nelisp_tmp/audit-emacs.err" >&2
    return 1
  fi
  compare_runtime_json audit "$nelisp_tmp/audit-emacs.json" "$nelisp_tmp/audit.json" \
    missing extra || return 1
  report_json_counts audit "$nelisp_tmp/audit.json" present missing extra || return 1
  check_profile_diff_candidates "$nelisp_tmp/audit.json" missing "$nelisp_max_missing" || return 1
  check_profile_diff_candidates "$nelisp_tmp/audit.json" extra "$nelisp_max_extra" || return 1

  if ! run_nelix_timed plan-dry-run "$nelisp_tmp/plan.json" "$nelisp_tmp/plan.err" \
    --runtime nelisp --json plan "$manifest" --dry-run; then
    sed -n '1,3p' "$nelisp_tmp/plan.json" >&2
    sed -n '1,20p' "$nelisp_tmp/plan.err" >&2
    return 1
  fi
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"status":"planned"' || return 1
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment plan "$nelisp_tmp/plan.json" '"backend":"nix"' || return 1
  if ! run_nelix_with_timeout --json plan "$manifest" --dry-run \
    >"$nelisp_tmp/plan-emacs.json" \
    2>"$nelisp_tmp/plan-emacs.err"; then
    sed -n '1,3p' "$nelisp_tmp/plan-emacs.json" >&2
    sed -n '1,20p' "$nelisp_tmp/plan-emacs.err" >&2
    return 1
  fi
  compare_runtime_json plan "$nelisp_tmp/plan-emacs.json" "$nelisp_tmp/plan.json" \
    install remove keep protected commands || return 1
  report_json_counts plan "$nelisp_tmp/plan.json" \
    install remove keep protected commands || return 1

  if ! run_nelix_timed apply-dry-run "$nelisp_tmp/apply-dry-run.json" "$nelisp_tmp/apply-dry-run.err" \
    --runtime nelisp --json apply "$manifest" --dry-run; then
    sed -n '1,3p' "$nelisp_tmp/apply-dry-run.json" >&2
    sed -n '1,20p' "$nelisp_tmp/apply-dry-run.err" >&2
    return 1
  fi
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"status":"dry-run"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"backend":"nix"' || return 1
  expect_json_fragment apply-dry-run "$nelisp_tmp/apply-dry-run.json" '"remove":[' || return 1
  if ! run_nelix_with_timeout --json apply "$manifest" --dry-run \
    >"$nelisp_tmp/apply-dry-run-emacs.json" \
    2>"$nelisp_tmp/apply-dry-run-emacs.err"; then
    sed -n '1,3p' "$nelisp_tmp/apply-dry-run-emacs.json" >&2
    sed -n '1,20p' "$nelisp_tmp/apply-dry-run-emacs.err" >&2
    return 1
  fi
  compare_runtime_json apply-dry-run \
    "$nelisp_tmp/apply-dry-run-emacs.json" \
    "$nelisp_tmp/apply-dry-run.json" \
    install remove keep protected commands || return 1
  report_json_counts apply-dry-run "$nelisp_tmp/apply-dry-run.json" \
    install remove keep protected commands || return 1
  compare_runtime_json plan-apply-dry-run \
    "$nelisp_tmp/plan.json" \
    "$nelisp_tmp/apply-dry-run.json" \
    install remove keep protected commands || return 1
  check_remove_candidates "$nelisp_tmp/apply-dry-run.json" || return 1

  if ! run_nelix_timed upgrade-plan "$nelisp_tmp/upgrade-plan.json" "$nelisp_tmp/upgrade-plan.err" \
    --runtime nelisp --json upgrade-plan "$manifest"; then
    sed -n '1,3p' "$nelisp_tmp/upgrade-plan.json" >&2
    sed -n '1,20p' "$nelisp_tmp/upgrade-plan.err" >&2
    return 1
  fi
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"operation":"upgrade"' || return 1
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"fallback":":nelisp-aot-cache"' || return 1
  expect_json_fragment upgrade-plan "$nelisp_tmp/upgrade-plan.json" '"backend":"nix"' || return 1
  if ! run_nelix_with_timeout --json upgrade-plan "$manifest" \
    >"$nelisp_tmp/upgrade-plan-emacs.json" \
    2>"$nelisp_tmp/upgrade-plan-emacs.err"; then
    sed -n '1,3p' "$nelisp_tmp/upgrade-plan-emacs.json" >&2
    sed -n '1,20p' "$nelisp_tmp/upgrade-plan-emacs.err" >&2
    return 1
  fi
  compare_runtime_json upgrade-plan \
    "$nelisp_tmp/upgrade-plan-emacs.json" \
    "$nelisp_tmp/upgrade-plan.json" \
    upgrade pinned missing || return 1
  report_json_counts upgrade-plan "$nelisp_tmp/upgrade-plan.json" \
    upgrade pinned missing || return 1

  if ! run_nelix_timed lock-check "$nelisp_tmp/lock-check.json" "$nelisp_tmp/lock-check.err" \
    --runtime nelisp --json lock-check "$manifest"; then
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

printf 'nelix user manifest %s ok: %s\n' "$verification_label" "$manifest"
