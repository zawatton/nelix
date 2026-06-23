;;; nelix-deps-standalone-driver.el --- Standalone dep-graph/inputs build -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Drives a MULTI-PACKAGE dependency build on the bare standalone NeLisp
;; binary (no Emacs, no Nix): registers libgreet (input) + useapp (depends
;; on libgreet), then builds useapp.  The executor recursively builds
;; libgreet first, injects its store path, and useapp's phase reads it via
;; (nelix-input "libgreet").  Verifies the dependency graph + store-path
;; injection (assoc-ref inputs) on standalone.  See `make
;; smoke-deps-inputs-standalone'.  Modeled on nelix-standalone-driver.el.

;;; Code:

(defun nelix-driver-log (fmt &rest args)
  (princ (apply #'format fmt args)) (princ "\n"))

(defun nelix-driver-fatal (msg)
  (princ (concat "FATAL: " msg "\n"))
  (if (fboundp 'nelisp-sys-exit) (nelisp-sys-exit 1) (error msg)))

(defvar nelix-driver--nelix-root "/home/madblack-21/Cowork/Notes/dev/nelix/")
(defvar nelix-driver--nelisp-root "/home/madblack-21/Cowork/Notes/dev/nelisp/")

;; Step 1 — nelisp-sys (chdir/mkdtemp/exit).
(load (concat nelix-driver--nelisp-root "packages/nelisp-sys/src/nelisp-sys.el") nil t)

;; Step 2 — shims.
(load (concat nelix-driver--nelix-root "scripts/nelix-standalone-shim.el") nil t)

;; Step 3 — XDG dirs via shell (standalone getenv returns nil).
(defun nelix-driver--shell-getenv (var)
  (let ((out (with-temp-buffer
               (call-process "/bin/sh" nil t nil "-c" (concat "printf '%s' \"$" var "\""))
               (buffer-string))))
    (if (and (stringp out) (> (length out) 0)) out nil)))

(defvar nelix-driver--xdg-data-home
  (or (nelix-driver--shell-getenv "XDG_DATA_HOME")
      (let ((h (nelix-driver--shell-getenv "HOME"))) (when h (concat h "/.local/share")))))
(defvar nelix-driver--xdg-state-home
  (or (nelix-driver--shell-getenv "XDG_STATE_HOME")
      (let ((h (nelix-driver--shell-getenv "HOME"))) (when h (concat h "/.local/state")))))

;; Step 4 — preset store roots + force-load nelix modules INCLUDING nelix-build
;; (the deps fixtures use Elisp-form phases: nelix-input/nelix-mkdir-p/etc.).
(when nelix-driver--xdg-data-home
  (setq nelix-store-root (concat nelix-driver--xdg-data-home "/nelix/store")))
(when nelix-driver--xdg-state-home
  (setq nelix-profile-root (concat nelix-driver--xdg-state-home "/nelix/profiles")))

(dolist (module '("nelix-compat.el" "nelix-build.el" "nelix-store.el"
                  "nelix-registry.el" "nelix-fetch.el" "nelix-backend.el"
                  "nelix-builder.el"))
  (nelix-driver-log "nelix-deps-standalone-driver: loading %s" module)
  (load (concat nelix-driver--nelix-root module) nil t))

;; Step 5 — register BOTH the input (libgreet) and the consumer (useapp).
(dolist (f '("test/fixtures/libgreet.el" "test/fixtures/useapp.el"))
  (condition-case err
      (nelix-registry--load-file (concat nelix-driver--nelix-root f))
    (error (nelix-driver-fatal (concat "failed to load " f ": "
                                       (error-message-string err))))))

;; Step 6 — build useapp (recursively builds libgreet first, injects its
;; store path via nelix-input).
(let ((recipe (nelix-registry-get "useapp")))
  (unless recipe (nelix-driver-fatal "nelix-registry-get returned nil for useapp"))
  (nelix-driver-log "nelix-deps-standalone-driver: building useapp (dep: libgreet) on standalone...")
  (condition-case err
      (let ((report (nelix-native-install-recipe recipe "default" 'x86_64-linux)))
        (nelix-driver-log "nelix-deps-standalone-driver: install-report: %S" report)
        (nelix-driver-log "nelix-deps-standalone-driver: SUCCESS"))
    (error (nelix-driver-fatal (concat "install failed: " (error-message-string err))))))

;;; nelix-deps-standalone-driver.el ends here
