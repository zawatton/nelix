;;; nelix-sandbox-deps-smoke.el --- host driver for smoke-sandbox-deps -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs driver for `make smoke-sandbox-deps' (Tier 2 / T1, design 32).
;; Builds `useapp' (which depends on `libgreet') under
;; `nelix-builder-hermeticity' = `tier2'.  The dependency `libgreet' builds
;; first IN ITS OWN SANDBOX (the tier2 dynamic binding spans the recursive
;; dependency build), is committed to the host store, and its store path is
;; injected into `useapp's phase inputs.  `useapp's sandbox bind-mounts that
;; store path READ-ONLY at its canonical path, so `(nelix-input "libgreet")'
;; resolves identically inside, the build reads libgreet's value file, and
;; the resulting binary exits 42 — proving the input-closure binding + the
;; (assoc-ref inputs) analogue work inside the namespace sandbox.

;;; Code:

(require 'nelix-registry)
(require 'nelix-builder)
(require 'nelix-sandbox)

(defvar nsd--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the nelix repository.")

(defvar nsd--failures 0)

(defun nsd-log (fmt &rest args)
  (princ (apply #'format fmt args)) (princ "\n"))

(defun nsd-fail (fmt &rest args)
  (setq nsd--failures (1+ nsd--failures))
  (nsd-log (concat "smoke-sandbox-deps: FAIL: " (apply #'format fmt args))))

(unless (nelix-sandbox-available-p 'bwrap)
  (nsd-log "smoke-sandbox-deps: SKIP — bwrap / unprivileged userns unavailable")
  (kill-emacs 0))

(let ((tmp (make-temp-file "nsd-" t)))
  (setq nelix-store-root (expand-file-name "store" tmp)
        nelix-profile-root (expand-file-name "profiles" tmp)))

(nelix-registry--load-file
 (expand-file-name "test/fixtures/libgreet.el" nsd--root))
(nelix-registry--load-file
 (expand-file-name "test/fixtures/useapp.el" nsd--root))

(condition-case e
    (let* ((nelix-builder-hermeticity 'tier2)
           (report (nelix-native-install-recipe
                    (nelix-registry-get "useapp") "default" 'x86_64-linux))
           (store-path (plist-get report :store-path))
           (deps (plist-get report :dependencies))
           (bin (expand-file-name "bin/useapp" store-path)))
      (nsd-log "store-path=%s" store-path)
      (nsd-log "dependencies built first (in sandbox): %S"
               (mapcar (lambda (d) (plist-get d :name)) deps))
      (unless (seq-find (lambda (d) (equal (plist-get d :name) "libgreet")) deps)
        (nsd-fail "libgreet not reported as a built dependency"))
      (if (file-exists-p bin)
          (let ((rc (call-process bin nil nil nil)))
            (if (eq rc 42)
                (nsd-log (concat "OK: useapp built inside the sandbox exits 42 — "
                                 "libgreet built sandboxed, its store path bound RO, "
                                 "(nelix-input \"libgreet\") resolved inside"))
              (nsd-fail "useapp exit %S (expected 42)" rc)))
        (nsd-fail "useapp binary not found at %s" bin)))
  (error (nsd-fail "tier2 deps build errored: %s" (error-message-string e))))

(if (eq nsd--failures 0)
    (nsd-log (concat "smoke-sandbox-deps: SUCCESS — dependency graph + "
                     "nelix-input store-path injection INSIDE the namespace sandbox, "
                     "network denied, no nix"))
  (progn
    (nsd-log "smoke-sandbox-deps: FAILURE (%d check(s) failed)" nsd--failures)
    (kill-emacs 1)))

;;; nelix-sandbox-deps-smoke.el ends here
