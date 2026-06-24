;;; nelix-sandbox-repro-smoke.el --- host driver for smoke-sandbox-repro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs driver for `make smoke-sandbox-repro' (Tier 2 / T3, design 32).
;;
;;   REPRODUCIBILITY: build `hello-native' TWICE in independent sandboxes
;;     (fresh store each time) and assert the output binary is BYTE-IDENTICAL
;;     (same sha256).  The Tier-1 deterministic env (SOURCE_DATE_EPOCH=1,
;;     TZ=UTC, LC_ALL=C) + the namespace isolation make the build a pure
;;     function of its declared inputs on a given host/toolchain.
;;   TOOLCHAIN-INPUT: assert the `:toolchain' SPEC field produces a read-only
;;     bind in the bwrap argv — the content-addressed-toolchain opt-in
;;     mechanism (so a pinned toolchain can drive cross-host reproducibility;
;;     building such a toolchain is out of scope, see design 32 §9).
;;
;; Determinism boundary (honest): bit-identical output holds for builds that
;; do not read entropy/time and on the same host toolchain.  /dev/urandom is
;; present (via --dev /dev); a build that reads it is non-deterministic — that
;; is the recipe's responsibility, not the sandbox's.

;;; Code:

(require 'nelix-registry)
(require 'nelix-builder)
(require 'nelix-sandbox)
(require 'nelix-fetch)

(defvar nsr--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the nelix repository.")

(defvar nsr--failures 0)

(defun nsr-log (fmt &rest args)
  (princ (apply #'format fmt args)) (princ "\n"))

(defun nsr-fail (fmt &rest args)
  (setq nsr--failures (1+ nsr--failures))
  (nsr-log (concat "smoke-sandbox-repro: FAIL: " (apply #'format fmt args))))

(defun nsr--build-hash ()
  "Build hello-native in a FRESH store under tier2; return the binary sha256."
  (let ((tmp (make-temp-file "nsr-" t)))
    (setq nelix-store-root (expand-file-name "store" tmp)
          nelix-profile-root (expand-file-name "profiles" tmp))
    (let* ((nelix-builder-hermeticity 'tier2)
           (report (nelix-native-install-recipe
                    (nelix-registry-get "hello-native") "default" 'x86_64-linux))
           (bin (expand-file-name "bin/hello" (plist-get report :store-path))))
      (unless (file-exists-p bin)
        (error "hello-native binary not built"))
      (nelix-fetch-sha256-file bin))))

(unless (nelix-sandbox-available-p 'bwrap)
  (nsr-log "smoke-sandbox-repro: SKIP — bwrap / unprivileged userns unavailable")
  (kill-emacs 0))

(nelix-registry--load-file
 (expand-file-name "test/fixtures/hello-native.el" nsr--root))

;; --- REPRODUCIBILITY: two independent sandbox builds must be byte-identical.
(condition-case e
    (let ((h1 (nsr--build-hash))
          (h2 (nsr--build-hash)))
      (nsr-log "build1=%s" h1)
      (nsr-log "build2=%s" h2)
      (if (equal h1 h2)
          (nsr-log "REPRO OK: two independent tier2 sandbox builds are byte-identical")
        (nsr-fail "builds are NOT identical: %s vs %s" h1 h2)))
  (error (nsr-fail "reproducibility build errored: %s" (error-message-string e))))

;; --- TOOLCHAIN-INPUT: a :toolchain path becomes a read-only bind in the argv.
(let* ((tc "/opt/nelix-test-toolchain")
       (argv (nelix-sandbox--bwrap-argv
              (list :phases nil :inputs nil :out "/tmp/o" :build "/tmp/b"
                    :net nil :toolchain (list tc))
              "/tmp/spec.el")))
  (if (member tc argv)
      (nsr-log "TOOLCHAIN-INPUT OK: :toolchain path produces a read-only bind in the bwrap argv")
    (nsr-fail "toolchain path %s not bound in argv" tc)))

(if (eq nsr--failures 0)
    (nsr-log (concat "smoke-sandbox-repro: SUCCESS — reproducible (byte-identical) "
                     "tier2 builds + content-addressed-toolchain opt-in mechanism, no nix"))
  (progn
    (nsr-log "smoke-sandbox-repro: FAILURE (%d check(s) failed)" nsr--failures)
    (kill-emacs 1)))

;;; nelix-sandbox-repro-smoke.el ends here
