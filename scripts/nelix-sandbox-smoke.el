;;; nelix-sandbox-smoke.el --- host driver for smoke-sandbox-bwrap -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs driver for `make smoke-sandbox-bwrap' (Tier 2, design 32).
;; The host orchestrator binds `nelix-builder-hermeticity' to `tier2', so
;; `nelix-builder--install-build' routes the build phases through
;; `nelix-sandbox-run' (bwrap backend); a builder child runs them inside a
;; namespace sandbox.
;;
;;   POSITIVE: build `hello-native' (shell-string phases, standalone-proven)
;;             under tier2 and assert the binary runs from the store.
;;   NEGATIVE: build `hello-sandbox-net' under tier2 and assert it FAILS,
;;             proving the build's network namespace is unshared.
;;   CONTROL:  run the same curl on the host (outside the sandbox); if it
;;             reaches the network the negative assertion is airtight.

;;; Code:

(require 'nelix-registry)
(require 'nelix-builder)
(require 'nelix-sandbox)

(defvar nss--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Root directory of the nelix repository.")

(defvar nss--failures 0)

(defun nss-log (fmt &rest args)
  (princ (apply #'format fmt args)) (princ "\n"))

(defun nss-fail (fmt &rest args)
  (setq nss--failures (1+ nss--failures))
  (nss-log (concat "smoke-sandbox-bwrap: FAIL: " (apply #'format fmt args))))

;; Sandbox preflight.
(unless (nelix-sandbox-available-p 'bwrap)
  (nss-log "smoke-sandbox-bwrap: SKIP — bwrap / unprivileged userns unavailable")
  (kill-emacs 0))

;; Per-run store + profile roots.
(let ((tmp (make-temp-file "nss-" t)))
  (setq nelix-store-root (expand-file-name "store" tmp)
        nelix-profile-root (expand-file-name "profiles" tmp)))

(defun nss--install (name)
  "Install fixture NAME under tier2; return the install report or signal."
  (let ((nelix-builder-hermeticity 'tier2))
    (nelix-native-install-recipe
     (nelix-registry-get name) "default" 'x86_64-linux)))

;; ---- POSITIVE: hello-native built inside the sandbox ----
(nelix-registry--load-file
 (expand-file-name "test/fixtures/hello-native.el" nss--root))
(condition-case e
    (let* ((report (nss--install "hello-native"))
           (store-path (plist-get report :store-path))
           (bin (expand-file-name "bin/hello" store-path)))
      (nss-log "positive: store-path=%s" store-path)
      (if (file-exists-p bin)
          (let ((out (with-temp-buffer
                       (let ((rc (call-process bin nil t nil)))
                         (cons rc (buffer-string))))))
            (if (and (eq (car out) 0)
                     (string-match-p "nelix-native-build-ok" (cdr out)))
                (nss-log "POSITIVE OK: tier2 sandboxed build ran from store (%s)"
                         (string-trim (cdr out)))
              (nss-fail "positive: binary rc=%S out=%S" (car out) (cdr out))))
        (nss-fail "positive: binary not found at %s" bin)))
  (error (nss-fail "positive: build errored: %s" (error-message-string e))))

;; ---- NEGATIVE: network-probe build must fail under tier2 ----
(nelix-registry--load-file
 (expand-file-name "test/fixtures/hello-sandbox-net.el" nss--root))
(let ((failed nil))
  (condition-case e
      (nss--install "hello-sandbox-net")
    (error
     (setq failed t)
     (nss-log "negative: build failed as expected: %s"
              (let ((m (error-message-string e)))
                (substring m 0 (min 160 (length m)))))))
  (if failed
      (nss-log "NEGATIVE OK: net-probe build failed under tier2 (network denied)")
    (nss-fail "negative: net-probe build SUCCEEDED under tier2 (network NOT denied!)")))

;; ---- CONTROL: host can reach the network (outside the sandbox) ----
(let ((rc (call-process "curl" nil nil nil
                        "-sS" "--max-time" "5" "-o" "/dev/null"
                        "https://1.1.1.1/")))
  (if (eq rc 0)
      (nss-log "CONTROL: host curl reached the network (rc=0) — the tier2 failure is the sandbox")
    (nss-log "CONTROL: host curl rc=%S (host offline?) — negative still holds, control inconclusive" rc)))

;; ---- verdict ----
(if (eq nss--failures 0)
    (nss-log "smoke-sandbox-bwrap: SUCCESS — tier2 build isolated in a namespace, network denied, no nix")
  (progn
    (nss-log "smoke-sandbox-bwrap: FAILURE (%d check(s) failed)" nss--failures)
    (kill-emacs 1)))

;;; nelix-sandbox-smoke.el ends here
