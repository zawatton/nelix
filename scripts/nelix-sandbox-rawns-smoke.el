;;; nelix-sandbox-rawns-smoke.el --- host driver for smoke-sandbox-rawns -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs driver for `make smoke-sandbox-rawns' (Tier 2 / T4, design 32).
;; Exercises the PURE-ELISP raw-ns backend (no bwrap): the standalone NeLisp
;; binary unshares the namespaces in-process via the `nelisp--syscall-unshare'
;; builtin (CLONE_NEWUSER + uid/gid map, then NEWNS|NEWNET|NEWUTS|NEWIPC) and
;; runs the build phases offline.
;;
;;   POSITIVE: build `hello-native' under :backend 'raw-ns and assert the
;;             binary runs from the store (prints nelix-native-build-ok).
;;   NEGATIVE: build `hello-sandbox-net' under raw-ns and assert it FAILS,
;;             proving the unshared network namespace is real (no route out).
;;   CONTROL:  host curl reaches the network, so the failure is the namespace.
;;
;; Selects the backend by binding `nelix-sandbox-backend' to 'raw-ns; the
;; rest of the path (tier2 routing, status-file protocol) is shared with bwrap.

;;; Code:

(require 'nelix-registry)
(require 'nelix-builder)
(require 'nelix-sandbox)

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
  (nsr-log (concat "smoke-sandbox-rawns: FAIL: " (apply #'format fmt args))))

(unless (nelix-sandbox-available-p 'raw-ns)
  (nsr-log "smoke-sandbox-rawns: SKIP — standalone NeLisp lacks nelisp--syscall-unshare or unprivileged userns unavailable")
  (kill-emacs 0))

(let ((tmp (make-temp-file "nsr-" t)))
  (setq nelix-store-root (expand-file-name "store" tmp)
        nelix-profile-root (expand-file-name "profiles" tmp)))

(defun nsr--install (name)
  "Install fixture NAME under tier2 with the raw-ns backend."
  (let ((nelix-builder-hermeticity 'tier2)
        (nelix-sandbox-backend 'raw-ns))
    (nelix-native-install-recipe
     (nelix-registry-get name) "default" 'x86_64-linux)))

;; ---- POSITIVE: hello-native built via the raw-ns backend ----
(nelix-registry--load-file
 (expand-file-name "test/fixtures/hello-native.el" nsr--root))
(condition-case e
    (let* ((report (nsr--install "hello-native"))
           (bin (expand-file-name "bin/hello" (plist-get report :store-path))))
      (nsr-log "positive: store-path=%s" (plist-get report :store-path))
      (if (file-exists-p bin)
          (let ((out (with-temp-buffer
                       (let ((rc (call-process bin nil t nil)))
                         (cons rc (buffer-string))))))
            (if (and (eq (car out) 0)
                     (string-match-p "nelix-native-build-ok" (cdr out)))
                (nsr-log "POSITIVE OK: raw-ns (pure-elisp, no bwrap) build ran from store (%s)"
                         (string-trim (cdr out)))
              (nsr-fail "positive: binary rc=%S out=%S" (car out) (cdr out))))
        (nsr-fail "positive: binary not found at %s" bin)))
  (error (nsr-fail "positive: build errored: %s" (error-message-string e))))

;; ---- NEGATIVE: network-probe build must fail under raw-ns (NEWNET) ----
(nelix-registry--load-file
 (expand-file-name "test/fixtures/hello-sandbox-net.el" nsr--root))
(let ((failed nil))
  (condition-case e
      (nsr--install "hello-sandbox-net")
    (error
     (setq failed t)
     (nsr-log "negative: build failed as expected: %s"
              (let ((m (error-message-string e)))
                (substring m 0 (min 160 (length m)))))))
  (if failed
      (nsr-log "NEGATIVE OK: net-probe build failed under raw-ns (network namespace unshared)")
    (nsr-fail "negative: net-probe build SUCCEEDED under raw-ns (network NOT denied!)")))

;; ---- CONTROL: host can reach the network ----
(let ((rc (call-process "curl" nil nil nil
                        "-sS" "--max-time" "5" "-o" "/dev/null"
                        "https://1.1.1.1/")))
  (if (eq rc 0)
      (nsr-log "CONTROL: host curl reached the network (rc=0) — the raw-ns failure is the namespace")
    (nsr-log "CONTROL: host curl rc=%S (host offline?) — negative still holds, control inconclusive" rc)))

;; ---- verdict ----
(if (eq nsr--failures 0)
    (nsr-log (concat "smoke-sandbox-rawns: SUCCESS — pure-elisp raw-ns backend (no bwrap, no Rust): "
                     "build isolated in namespaces, network denied"))
  (progn
    (nsr-log "smoke-sandbox-rawns: FAILURE (%d check(s) failed)" nsr--failures)
    (kill-emacs 1)))

;;; nelix-sandbox-rawns-smoke.el ends here
