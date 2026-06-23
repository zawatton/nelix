;;; nelix-standalone-driver.el --- Drive nelix native build on standalone NeLisp -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Standalone driver that builds hello-native via the nelix-native
;; executor on the bare NeLisp binary (no Emacs, no Nix).
;;
;; SUCCESS CRITERION command:
;;
;;   NELIX=/home/madblack-21/Cowork/Notes/dev/nelix
;;   NELISP=/home/madblack-21/Cowork/Notes/dev/nelisp
;;   tmp=$(mktemp -d); mkdir -p $tmp/h $tmp/d $tmp/s
;;   env -i PATH=/usr/bin:/bin HOME=$tmp/h XDG_DATA_HOME=$tmp/d \
;;           XDG_STATE_HOME=$tmp/s \
;;     $NELISP/target/nelisp \
;;       --load $NELIX/scripts/nelix-standalone-driver.el
;;
;;   # Verify the built binary:
;;   find $tmp/d/nelix/store -name hello -type f
;;   <path-from-find>          # should print "nelix-native-build-ok"

;;; Code:

;;; Portable output helpers (standalone NeLisp has no `message').

(defun nelix-driver-log (fmt &rest args)
  "Print a log line to stdout via `princ'."
  (princ (apply #'format fmt args))
  (princ "\n"))

(defun nelix-driver-fatal (msg)
  "Print MSG as a fatal message and exit 1."
  (princ (concat "FATAL: " msg "\n"))
  (if (fboundp 'nelisp-sys-exit)
      (nelisp-sys-exit 1)
    (error msg)))

;;; Canonical directory roots.

(defvar nelix-driver--nelix-root
  "/home/madblack-21/Cowork/Notes/dev/nelix/"
  "Root directory of the nelix repository (trailing slash required).")

(defvar nelix-driver--nelisp-root
  "/home/madblack-21/Cowork/Notes/dev/nelisp/"
  "Root directory of the nelisp repository (trailing slash required).")

;;; Step 1 — Force-load nelisp-sys so nelisp-sys-chdir is available.

(let ((nelisp-sys-el (concat nelix-driver--nelisp-root
                             "packages/nelisp-sys/src/nelisp-sys.el")))
  (nelix-driver-log "nelix-standalone-driver: loading nelisp-sys from %s"
                    nelisp-sys-el)
  (load nelisp-sys-el nil t))

(nelix-driver-log "nelix-standalone-driver: nelisp-sys-chdir fbound: %s"
                  (if (fboundp 'nelisp-sys-chdir) "t" "nil"))

;;; Step 2 — Load pure-elisp shims for missing primitives.

(let ((shim-file (concat nelix-driver--nelix-root
                         "scripts/nelix-standalone-shim.el")))
  (nelix-driver-log "nelix-standalone-driver: loading shims from %s" shim-file)
  (load shim-file nil t)
  (nelix-driver-log "nelix-standalone-driver: shell-quote-argument fbound: %s"
                    (if (fboundp 'shell-quote-argument) "t" "nil")))

;;; Step 3 — Resolve XDG dirs from the shell environment.
;;; `getenv' on standalone NeLisp always returns nil (process-environment is
;;; not populated from the OS envp).  Use `call-process /bin/sh' to read the
;;; actual environment instead.

(defun nelix-driver--shell-getenv (var)
  "Return environment variable VAR via a shell subprocess, or nil."
  (let ((out (with-temp-buffer
               (call-process "/bin/sh" nil t nil
                             "-c" (concat "printf '%s' \"$" var "\""))
               (buffer-string))))
    (if (and (stringp out) (> (length out) 0)) out nil)))

(defvar nelix-driver--xdg-data-home
  (or (nelix-driver--shell-getenv "XDG_DATA_HOME")
      (let ((home (nelix-driver--shell-getenv "HOME")))
        (when home (concat home "/.local/share"))))
  "Resolved XDG_DATA_HOME directory (may be nil if HOME unset too).")

(defvar nelix-driver--xdg-state-home
  (or (nelix-driver--shell-getenv "XDG_STATE_HOME")
      (let ((home (nelix-driver--shell-getenv "HOME")))
        (when home (concat home "/.local/state"))))
  "Resolved XDG_STATE_HOME directory.")

(nelix-driver-log "nelix-standalone-driver: XDG_DATA_HOME  = %s"
                  (or nelix-driver--xdg-data-home "(unresolved)"))
(nelix-driver-log "nelix-standalone-driver: XDG_STATE_HOME = %s"
                  (or nelix-driver--xdg-state-home "(unresolved)"))

;;; Step 4 — Force-load all nelix modules.
;;; Pre-set nelix-store-root / nelix-profile-root BEFORE the modules load
;;; so the defcustom defaults are pre-filled; this avoids the getenv path
;;; entirely.

(when nelix-driver--xdg-data-home
  (setq nelix-store-root
        (concat nelix-driver--xdg-data-home "/nelix/store")))

(when nelix-driver--xdg-state-home
  (setq nelix-profile-root
        (concat nelix-driver--xdg-state-home "/nelix/profiles")))

(let ((modules '("nelix-compat.el"
                 "nelix-store.el"
                 "nelix-registry.el"
                 "nelix-fetch.el"
                 "nelix-backend.el"
                 "nelix-builder.el")))
  (dolist (module modules)
    (let ((path (concat nelix-driver--nelix-root module)))
      (nelix-driver-log "nelix-standalone-driver: loading %s" module)
      (load path nil t))))

;;; Step 5 — Load the recipe and register it with the in-memory registry.

(let ((recipe-file (concat nelix-driver--nelix-root
                           "test/fixtures/hello-native.el")))
  (nelix-driver-log "nelix-standalone-driver: registering recipe from %s"
                    recipe-file)
  (condition-case err
      (nelix-registry--load-file recipe-file)
    (error
     (nelix-driver-fatal
      (concat "failed to load recipe: " (error-message-string err))))))

;;; Step 6 — Retrieve recipe from registry and install (build).

(let ((recipe (nelix-registry-get "hello-native")))
  (unless recipe
    (nelix-driver-fatal "nelix-registry-get returned nil for hello-native"))
  (nelix-driver-log "nelix-standalone-driver: recipe: %s %s"
                    (plist-get recipe :name)
                    (plist-get recipe :version))
  (nelix-driver-log "nelix-standalone-driver: store root: %s"
                    (or nelix-store-root "(auto)"))
  (nelix-driver-log "nelix-standalone-driver: starting build (system: x86_64-linux)...")
  (condition-case err
      (let ((report (nelix-native-install-recipe recipe "default" 'x86_64-linux)))
        (nelix-driver-log "nelix-standalone-driver: install-report: %S" report)
        (nelix-driver-log "nelix-standalone-driver: SUCCESS"))
    (error
     (nelix-driver-fatal
      (concat "install failed: " (error-message-string err))))))

;;; nelix-standalone-driver.el ends here
