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
  expected_deb_version="${NELIX_INIT_MIGRATION_EXPECTED_DEB_VERSION:-0.1.0-4}"
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

compare_init_json() {
  label="$1"
  left_json="$2"
  right_json="$3"
  shift 3
  emacs -Q --batch \
    -l "$repo_dir/packaging/compare-nelix-json.el" \
    -- "$label" "$left_json" "$right_json" "$@"
}

json_tmp="$(mktemp -d)"
cleanup_json() {
  rm -rf "$json_tmp"
}
trap cleanup_json EXIT HUP INT TERM

run_nelix_json --runtime nelisp --json validate "$manifest"
run_nelix_json --runtime nelisp --json list
run_nelix_json --runtime nelisp --json audit "$manifest"
run_nelix_json_capture "$json_tmp/plan.json" --runtime nelisp --json plan "$manifest" --dry-run
run_nelix_json_capture "$json_tmp/apply-dry-run.json" --runtime nelisp --json apply "$manifest" --dry-run
compare_init_json init-plan-apply-dry-run \
  "$json_tmp/plan.json" \
  "$json_tmp/apply-dry-run.json" \
  install remove keep protected commands
run_nelix_json --runtime nelisp --json upgrade-plan "$manifest"
run_nelix_json --runtime nelisp --json lock-check "$manifest"

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
  run_nelix_json --runtime nelisp --json apply "$manifest" --locked --dry-run
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
