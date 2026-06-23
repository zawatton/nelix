;;; nelix-guix-standalone-driver.el --- Guix->ldb->nelix full pipeline on standalone NeLisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone driver that exercises the FULL pipeline on the bare NeLisp
;; binary (no Emacs, no Nix):
;;
;;   Guix .scm recipe
;;     -> ldb-guix-import-native-string   (ldb translates Scheme -> nelix form)
;;     -> nelix-registry--load-file       (registers the translated recipe)
;;     -> nelix-native-install-recipe     (nelix executor builds from source)
;;     -> binary verify                   (asserts exit code 42)
;;
;; SUCCESS CRITERION command (example):
;;
;;   NELIX=/home/madblack-21/Cowork/Notes/dev/nelix
;;   NELISP=/home/madblack-21/Cowork/Notes/dev/nelisp
;;   LDB=/home/madblack-21/Cowork/Notes/dev/lisp-dialect-bridge
;;   tmp=$(mktemp -d); mkdir -p $tmp/h $tmp/d $tmp/s $tmp/bin
;;   printf '#!/bin/sh\necho INVOKED >> %s/nixlog\nexit 127\n' "$tmp" \
;;     > "$tmp/bin/nix"; chmod +x "$tmp/bin/nix"; : > "$tmp/nixlog"
;;   env -i PATH="$tmp/bin:/usr/bin:/bin" HOME=$tmp/h \
;;           XDG_DATA_HOME=$tmp/d XDG_STATE_HOME=$tmp/s \
;;     $NELISP/target/nelisp \
;;       --load $NELIX/scripts/nelix-guix-standalone-driver.el \
;;     2>&1 | grep -E "SUCCESS|FATAL|error" || true
;;   store_bin=$(find $tmp/d/nelix/store -name hello-guix -type f | head -1)
;;   env -i PATH=/usr/bin:/bin "$store_bin"; echo "exit: $?"   # should print 42
;;   test ! -s "$tmp/nixlog" && echo "nix NOT invoked (poison log empty)"

;;; Code:

;;; ── Portable output helpers (no `message' on standalone) ─────────────────

(defun nelix-guix-driver-log (fmt &rest args)
  "Print a log line to stdout."
  (princ (apply #'format fmt args))
  (princ "\n"))

(defun nelix-guix-driver-fatal (msg)
  "Print MSG as a FATAL error and exit 1."
  (princ (concat "FATAL: " msg "\n"))
  (if (fboundp 'nelisp-sys-exit)
      (nelisp-sys-exit 1)
    (error msg)))

;;; ── Canonical roots ──────────────────────────────────────────────────────

(defvar nelix-guix-driver--nelix-root
  "/home/madblack-21/Cowork/Notes/dev/nelix/"
  "Root directory of the nelix repository (trailing slash required).")

(defvar nelix-guix-driver--nelisp-root
  "/home/madblack-21/Cowork/Notes/dev/nelisp/"
  "Root directory of the nelisp repository (trailing slash required).")

(defvar nelix-guix-driver--ldb-root
  "/home/madblack-21/Cowork/Notes/dev/lisp-dialect-bridge/"
  "Root directory of the lisp-dialect-bridge repository (trailing slash required).")

;;; ── Step 1: load nelisp-sys (provides nelisp-sys-chdir, nelisp-sys-exit) ─

(let ((p (concat nelix-guix-driver--nelisp-root
                 "packages/nelisp-sys/src/nelisp-sys.el")))
  (nelix-guix-driver-log "nelix-guix-standalone-driver: loading nelisp-sys from %s" p)
  (load p nil t))

;;; ── Step 2: load nelix standalone shims ──────────────────────────────────

(let ((p (concat nelix-guix-driver--nelix-root
                 "scripts/nelix-standalone-shim.el")))
  (nelix-guix-driver-log "nelix-guix-standalone-driver: loading nelix shims from %s" p)
  (load p nil t))

;;; ── Step 3: load ldb modules ─────────────────────────────────────────────

(nelix-guix-driver-log "nelix-guix-standalone-driver: loading lisp-dialect-bridge modules...")
(dolist (mod '("ldb-ir.el" "ldb-scheme.el" "ldb-emit-elisp.el" "ldb-guix-importer.el"))
  (let ((p (concat nelix-guix-driver--ldb-root mod)))
    (nelix-guix-driver-log "  loading %s" mod)
    (condition-case err
        (load p nil t)
      (error (nelix-guix-driver-fatal
              (concat "failed to load " mod ": " (error-message-string err)))))))

;;; ── Step 4: resolve XDG dirs from shell environment ──────────────────────
;;; (Same pattern as nelix-standalone-driver.el — getenv is nil on standalone)

(defun nelix-guix-driver--shell-getenv (var)
  "Return environment variable VAR via a shell subprocess, or nil."
  (let ((out (with-temp-buffer
               (call-process "/bin/sh" nil t nil
                             "-c" (concat "printf '%s' \"$" var "\""))
               (buffer-string))))
    (if (and (stringp out) (> (length out) 0)) out nil)))

(defvar nelix-guix-driver--xdg-data-home
  (or (nelix-guix-driver--shell-getenv "XDG_DATA_HOME")
      (let ((home (nelix-guix-driver--shell-getenv "HOME")))
        (when home (concat home "/.local/share")))))

(defvar nelix-guix-driver--xdg-state-home
  (or (nelix-guix-driver--shell-getenv "XDG_STATE_HOME")
      (let ((home (nelix-guix-driver--shell-getenv "HOME")))
        (when home (concat home "/.local/state")))))

(nelix-guix-driver-log "nelix-guix-standalone-driver: XDG_DATA_HOME  = %s"
                       (or nelix-guix-driver--xdg-data-home "(unresolved)"))
(nelix-guix-driver-log "nelix-guix-standalone-driver: XDG_STATE_HOME = %s"
                       (or nelix-guix-driver--xdg-state-home "(unresolved)"))

;;; ── Step 5: load nelix modules (pre-set store roots) ─────────────────────

(when nelix-guix-driver--xdg-data-home
  (setq nelix-store-root
        (concat nelix-guix-driver--xdg-data-home "/nelix/store")))

(when nelix-guix-driver--xdg-state-home
  (setq nelix-profile-root
        (concat nelix-guix-driver--xdg-state-home "/nelix/profiles")))

(nelix-guix-driver-log "nelix-guix-standalone-driver: loading nelix modules...")
(dolist (mod '("nelix-compat.el" "nelix-store.el" "nelix-registry.el"
               "nelix-fetch.el" "nelix-backend.el" "nelix-builder.el"))
  (let ((p (concat nelix-guix-driver--nelix-root mod)))
    (nelix-guix-driver-log "  loading %s" mod)
    (condition-case err
        (load p nil t)
      (error (nelix-guix-driver-fatal
              (concat "failed to load " mod ": " (error-message-string err)))))))

;;; ── Step 6: read and translate the Guix .scm recipe via ldb ─────────────

(defvar nelix-guix-driver--scm-path
  (concat nelix-guix-driver--nelix-root "test/fixtures/hello-guix.scm")
  "Path to the Guix Scheme recipe to import.")

(nelix-guix-driver-log "nelix-guix-standalone-driver: importing Guix recipe from %s"
                       nelix-guix-driver--scm-path)

(defvar nelix-guix-driver--native-recipe nil)

(condition-case err
    (let* ((scm (with-temp-buffer
                  (insert-file-contents nelix-guix-driver--scm-path)
                  (buffer-string)))
           (recipe (ldb-guix-import-native-string scm 'hello-guix)))
      (nelix-guix-driver-log "nelix-guix-standalone-driver: ldb translation OK")
      (nelix-guix-driver-log "  translated: %S" recipe)
      (setq nelix-guix-driver--native-recipe recipe))
  (error
   (nelix-guix-driver-fatal
    (concat "ldb translation failed: " (error-message-string err)))))

;;; ── Step 7: write the translated recipe to a temp file and register it ───

(defvar nelix-guix-driver--recipe-tmp-file nil)

(condition-case err
    (let* ((tmp-dir (or nelix-guix-driver--xdg-data-home "/tmp"))
           (recipe-file (concat tmp-dir "/hello-guix-native-standalone.el")))
      (nelix-guix-driver-log
       "nelix-guix-standalone-driver: writing recipe to %s" recipe-file)
      ;; Write a self-contained recipe file that nelix-registry--load-file
      ;; can load.  The file must not use `require' — force-load only.
      ;; Use write-region (pure string) — with-temp-file uses current-buffer
      ;; which is not available on standalone NeLisp.
      (write-region
       (concat ";;; -*- lexical-binding: t; -*-\n"
               (prin1-to-string nelix-guix-driver--native-recipe)
               "\n")
       nil recipe-file nil 'silent)
      (setq nelix-guix-driver--recipe-tmp-file recipe-file)
      (nelix-guix-driver-log
       "nelix-guix-standalone-driver: registering recipe via nelix-registry--load-file")
      (nelix-registry--load-file recipe-file)
      (nelix-guix-driver-log "nelix-guix-standalone-driver: recipe registered OK"))
  (error
   (nelix-guix-driver-fatal
    (concat "recipe registration failed: " (error-message-string err)))))

;;; ── Step 8: retrieve recipe and build via nelix-native executor ──────────

(let ((recipe (nelix-registry-get "hello-guix")))
  (unless recipe
    (nelix-guix-driver-fatal "nelix-registry-get returned nil for hello-guix"))
  (nelix-guix-driver-log "nelix-guix-standalone-driver: building %s %s (system: x86_64-linux)..."
                         (plist-get recipe :name)
                         (plist-get recipe :version))
  (nelix-guix-driver-log "nelix-guix-standalone-driver: store root: %s"
                         (or nelix-store-root "(auto)"))
  (condition-case err
      (let ((report (nelix-native-install-recipe recipe "default" 'x86_64-linux)))
        (nelix-guix-driver-log "nelix-guix-standalone-driver: install report: %S" report)
        (nelix-guix-driver-log "nelix-guix-standalone-driver: SUCCESS"))
    (error
     (nelix-guix-driver-fatal
      (concat "install failed: " (error-message-string err))))))

;;; nelix-guix-standalone-driver.el ends here
