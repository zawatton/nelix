#!/bin/sh
set -eu

repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
elpa_src_dir=/usr/share/emacs/site-lisp/elpa-src/nelix-0.1.0

"$repo_dir/packaging/verify-installed-nelix-debian.sh"

target_user="${NELIX_VERIFY_USER:-${SUDO_USER:-}}"
if [ "$(id -u)" -eq 0 ] && [ -n "$target_user" ] && [ "$target_user" != root ]; then
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
else
  target_user="$(id -un)"
  target_home="$HOME"
fi

if [ -z "$target_home" ] || [ ! -d "$target_home/.emacs.d" ]; then
  echo "Nelix user environment home is missing: user=$target_user home=$target_home" >&2
  exit 1
fi

run_user_emacs() {
  if [ "$(id -u)" -eq 0 ] && [ "$target_user" != root ]; then
    runuser -u "$target_user" -- env HOME="$target_home" emacs "$@"
  else
    env HOME="$target_home" emacs "$@"
  fi
}

manifest="$target_home/.emacs.d/nelix-package.el"
if [ ! -f "$manifest" ]; then
  echo "Nelix user manifest is missing: $manifest" >&2
  exit 1
fi

run_user_emacs -Q --batch \
  --eval "(let ((read-eval nil) (environment-forms 0) (manifest-forms 0)) (with-temp-buffer (insert-file-contents \"$manifest\") (goto-char (point-min)) (condition-case err (while t (let ((form (read (current-buffer)))) (when (and (consp form) (eq (car form) 'nelix-environment)) (setq environment-forms (1+ environment-forms))) (when (and (consp form) (eq (car form) 'nelix-manifest)) (setq manifest-forms (1+ manifest-forms))))) (end-of-file nil))) (unless (= environment-forms 1) (error \"Nelix user manifest must contain exactly one top-level nelix-environment form, got %S\" environment-forms)) (unless (= manifest-forms 0) (error \"Nelix user manifest must use DSL v1, not top-level nelix-manifest\")) (princ \"nelix user manifest DSL v1 ok\\n\"))"

run_user_emacs -Q --batch \
  -L "$elpa_src_dir" \
  -L "$target_home/.emacs.d/custom-lisp" \
  --eval "(setq load-prefer-newer t)" \
  --eval "(require 'nelix-manifest)" \
  --eval "(let* ((manifest-file (expand-file-name \"~/.emacs.d/nelix-package.el\")) (validation (nelix-validate manifest-file)) (audit (nelix-audit manifest-file)) (counts (plist-get validation :counts))) (unless (plist-get validation :ok) (error \"Nelix manifest validation failed\")) (unless (plist-get audit :ok) (error \"Nelix environment audit failed: %S\" audit)) (princ (format \"nelix user environment ok: packages=%S linux=%S\\n\" (+ (plist-get counts :emacs) (plist-get counts :linux) (plist-get counts :debian-tools)) t)))"
