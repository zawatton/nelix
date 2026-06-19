#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

target_user="${NELIX_VERIFY_USER:-${SUDO_USER:-}}"
if [ "$(id -u)" -eq 0 ] && [ -n "$target_user" ] && [ "$target_user" != root ]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
else
  target_user="$(id -un)"
  target_home="$HOME"
fi

if [ -z "$target_home" ] || [ ! -d "$target_home/.emacs.d" ]; then
  echo "Nelix init migration home is missing: user=$target_user home=$target_home" >&2
  exit 1
fi

manifest="${NELIX_USER_MANIFEST:-$target_home/.emacs.d/nelix-package.el}"
init_file="${NELIX_USER_INIT:-$target_home/.emacs.d/init.el}"
early_init_file="${NELIX_USER_EARLY_INIT:-$target_home/.emacs.d/early-init.el}"
audit_mode="${NELIX_INIT_MIGRATION_AUDIT:-required}"
max_missing="${NELIX_INIT_MIGRATION_MAX_MISSING:-${NELIX_USER_MANIFEST_MAX_MISSING:-}}"
max_extra="${NELIX_INIT_MIGRATION_MAX_EXTRA:-${NELIX_USER_MANIFEST_MAX_EXTRA:-}}"
max_remove="${NELIX_INIT_MIGRATION_MAX_REMOVE:-${NELIX_USER_MANIFEST_MAX_REMOVE:-}}"
nelisp_max_seconds="${NELIX_INIT_MIGRATION_NELISP_MAX_SECONDS:-${NELIX_USER_MANIFEST_NELISP_MAX_SECONDS:-5}}"
nelisp_min_targets="${NELIX_INIT_MIGRATION_MIN_TARGETS:-${NELIX_USER_MANIFEST_MIN_TARGETS:-0}}"

if [ ! -f "$manifest" ]; then
  echo "Nelix user manifest is missing: $manifest" >&2
  exit 1
fi

if [ ! -f "$init_file" ]; then
  echo "Emacs init file is missing: $init_file" >&2
  exit 1
fi

case "$audit_mode" in
  required|load-only) ;;
  *)
    echo "invalid NELIX_INIT_MIGRATION_AUDIT value: $audit_mode" >&2
    exit 64
    ;;
esac

for limit_name in max_missing max_extra max_remove; do
  eval "limit_value=\${$limit_name}"
  case "$limit_value" in
    ''|*[!0-9]*)
      if [ -n "$limit_value" ]; then
        echo "invalid $limit_name value: $limit_value" >&2
        exit 64
      fi
      ;;
  esac
done

case "$nelisp_max_seconds" in
  ''|*[!0-9]*)
    echo "invalid NELIX_INIT_MIGRATION_NELISP_MAX_SECONDS value: $nelisp_max_seconds" >&2
    exit 64
    ;;
esac

case "$nelisp_min_targets" in
  ''|*[!0-9]*)
    echo "invalid NELIX_INIT_MIGRATION_MIN_TARGETS value: $nelisp_min_targets" >&2
    exit 64
    ;;
esac

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

check_deb_version() {
  expected_deb_version="${NELIX_INIT_MIGRATION_EXPECTED_DEB_VERSION:-0.1.0-5}"
  if ! command -v dpkg-query >/dev/null 2>&1; then
    echo "dpkg-query is required for Debian package version verification" >&2
    exit 1
  fi
  installed_deb_version="$(dpkg-query -W -f='${Version}' elpa-nelix 2>/dev/null || true)"
  if [ -z "$installed_deb_version" ]; then
    echo "elpa-nelix is not installed; install the Debian package before init migration verification" >&2
    exit 1
  fi
  if ! dpkg --compare-versions "$installed_deb_version" ge "$expected_deb_version"; then
    echo "elpa-nelix is too old for init migration: installed=$installed_deb_version expected>=$expected_deb_version" >&2
    exit 1
  fi
}

resolved_nelix_bin="$nelix_bin"
case "$nelix_bin" in
  */*) ;;
  *) resolved_nelix_bin="$(command -v "$nelix_bin" 2>/dev/null || printf '%s' "$nelix_bin")" ;;
esac

case "${NELIX_INIT_MIGRATION_REQUIRE_DEB:-auto}" in
  1|true|yes|required)
    check_deb_version
    ;;
  0|false|no|skip)
    ;;
  auto)
    if [ "$resolved_nelix_bin" = /usr/bin/nelix ] ||
       [ "$nelix_lispdir" = /usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0 ]; then
      check_deb_version
    fi
    ;;
  *)
    echo "invalid NELIX_INIT_MIGRATION_REQUIRE_DEB value: ${NELIX_INIT_MIGRATION_REQUIRE_DEB}" >&2
    exit 64
    ;;
esac

run_nelix_json() {
  env NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" "$@" >/dev/null
}

run_nelix_json_capture() {
  out="$1"
  shift
  env NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" "$@" >"$out"
}

run_nelix_timed() {
  label="$1"
  out="$2"
  shift 2
  start="$(date +%s)"
  if env NELIX_LISPDIR="$nelix_lispdir" "$nelix_bin" "$@" >"$out"; then
    rc=0
  else
    rc=$?
  fi
  end="$(date +%s)"
  elapsed=$((end - start))
  printf 'nelix init migration timing: %s elapsed=%ss max=%ss\n' \
    "$label" "$elapsed" "$nelisp_max_seconds" >&2
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if [ "$nelisp_max_seconds" -gt 0 ] && [ "$elapsed" -gt "$nelisp_max_seconds" ]; then
    echo "nelix init migration $label exceeded NELIX_INIT_MIGRATION_NELISP_MAX_SECONDS=${nelisp_max_seconds}s" >&2
    return 1
  fi
}

compare_init_json() {
  label="$1"
  left_json="$2"
  right_json="$3"
  shift 3
  emacs -Q --batch \
    -l "$repo_dir/packaging/compare-nelix-json.el" \
    -- "$label" "$left_json" "$right_json" "$@"
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
  printf 'nelix init migration %s-count: %s\n' "$label" "$count" >&2
}

report_json_counts() {
  label="$1"
  file="$2"
  shift 2
  printf 'nelix init migration %s-counts:' "$label" >&2
  for key in "$@"; do
    count="$(json_array_count "$file" "$key")" || return 1
    printf ' %s=%s' "$key" "$count" >&2
  done
  printf '\n' >&2
}

check_json_array_limit() {
  label="$1"
  file="$2"
  key="$3"
  limit="$4"
  count="$(json_array_count "$file" "$key")" || return 1
  names="$(json_array_names "$file" "$key")" || return 1
  printf 'nelix init migration %s-count: %s max=%s names=%s\n' \
    "$label" "$count" "${limit:-none}" "${names:-none}" >&2
  if [ -n "$limit" ] && [ "$count" -gt "$limit" ]; then
    echo "nelix init migration $label count $count exceeds limit $limit" >&2
    return 1
  fi
}

json_tmp="$(mktemp -d)"
cleanup_json() {
  rm -rf "$json_tmp"
}
trap cleanup_json EXIT HUP INT TERM

run_nelix_timed aot-cache "$json_tmp/aot-cache.out" \
  --runtime nelisp aot-cache "$manifest"
if ! grep -Fq ':status ok' "$json_tmp/aot-cache.out"; then
  echo "nelix init migration aot-cache did not report ok" >&2
  sed -n '1,20p' "$json_tmp/aot-cache.out" >&2
  exit 1
fi
target_count="$(
  grep -c '^target-id[[:space:]]' "$manifest.nelix-aot-targets" 2>/dev/null ||
    printf '0\n'
)"
printf 'nelix init migration target-count: %s min=%s\n' \
  "$target_count" "$nelisp_min_targets" >&2
if [ "$nelisp_min_targets" -gt 0 ] && [ "$target_count" -lt "$nelisp_min_targets" ]; then
  echo "nelix init migration target count $target_count is below NELIX_INIT_MIGRATION_MIN_TARGETS=$nelisp_min_targets" >&2
  exit 1
fi

run_nelix_timed validate "$json_tmp/validate.json" \
  --runtime nelisp --json validate "$manifest"
run_nelix_timed list "$json_tmp/list.json" \
  --runtime nelisp --json list
report_top_level_count list "$json_tmp/list.json"
run_nelix_timed audit "$json_tmp/audit.json" \
  --runtime nelisp --json audit "$manifest"
report_json_counts audit "$json_tmp/audit.json" present missing extra
run_nelix_timed plan-dry-run "$json_tmp/plan.json" \
  --runtime nelisp --json plan "$manifest" --dry-run
report_json_counts plan "$json_tmp/plan.json" \
  install remove keep protected commands
run_nelix_timed apply-dry-run "$json_tmp/apply-dry-run.json" \
  --runtime nelisp --json apply "$manifest" --dry-run
report_json_counts apply-dry-run "$json_tmp/apply-dry-run.json" \
  install remove keep protected commands
check_json_array_limit audit-missing "$json_tmp/audit.json" missing "$max_missing"
check_json_array_limit audit-extra "$json_tmp/audit.json" extra "$max_extra"
check_json_array_limit remove "$json_tmp/apply-dry-run.json" remove "$max_remove"
compare_init_json init-plan-apply-dry-run \
  "$json_tmp/plan.json" \
  "$json_tmp/apply-dry-run.json" \
  install remove keep protected commands
run_nelix_timed upgrade-plan "$json_tmp/upgrade-plan.json" \
  --runtime nelisp --json upgrade-plan "$manifest"
report_json_counts upgrade-plan "$json_tmp/upgrade-plan.json" \
  upgrade pinned missing
run_nelix_timed lock-check "$json_tmp/lock-check.json" \
  --runtime nelisp --json lock-check "$manifest"

(
  lock_tmp="$(mktemp -d)"
  lock_file="$manifest.nelix-lock"
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

  run_nelix_json --json lock "$manifest"
  run_nelix_timed locked-apply-dry-run "$lock_tmp/locked-apply-dry-run.json" \
    --runtime nelisp --json apply "$manifest" --locked --dry-run
)

rm -rf "$json_tmp"
trap - EXIT HUP INT TERM

elisp="$(mktemp)"
trap 'rm -f "$elisp"' EXIT HUP INT TERM
cat >"$elisp" <<EOF
(setq load-prefer-newer t)
(add-to-list 'load-path (expand-file-name "custom-lisp" "$target_home/.emacs.d/"))
(when (file-directory-p "$nelix_lispdir")
  (add-to-list 'load-path "$nelix_lispdir"))
(when (file-exists-p "$early_init_file")
  (load-file "$early_init_file"))
(load-file "$init_file")
(unless (fboundp 'my-nelix-audit)
  (error "my-nelix-audit is missing after init load"))
(if (string= "$audit_mode" "load-only")
    (princ
     (format "nelix user init migration load ok: manifest=%s init=%s\\n"
             "$manifest" "$init_file"))
  (let ((audit (my-nelix-audit)))
    (unless (and (plist-get audit :package)
                 (plist-get audit :linux))
      (error "my-nelix-audit returned malformed result: %S" audit))
    (princ
     (format "nelix user init migration ok: manifest=%s init=%s\\n"
             "$manifest" "$init_file"))))
EOF

if command -v timeout >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ] && [ "$target_user" != root ]; then
    runuser -u "$target_user" -- env HOME="$target_home" \
      timeout "${NELIX_INIT_MIGRATION_TIMEOUT:-120s}" emacs -Q --batch -l "$elisp"
  else
    env HOME="$target_home" \
      timeout "${NELIX_INIT_MIGRATION_TIMEOUT:-120s}" emacs -Q --batch -l "$elisp"
  fi
else
  if [ "$(id -u)" -eq 0 ] && [ "$target_user" != root ]; then
    runuser -u "$target_user" -- env HOME="$target_home" \
      emacs -Q --batch -l "$elisp"
  else
    env HOME="$target_home" emacs -Q --batch -l "$elisp"
  fi
fi

rm -f "$elisp"
trap - EXIT HUP INT TERM
