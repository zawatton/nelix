;;; nelix-sandbox-fod-smoke.el --- host driver for smoke-sandbox-fod -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Host-Emacs driver for `make smoke-sandbox-fod' (Tier 2 / T2, design 32).
;; Exercises the fixed-output-derivation path: a recipe whose :source is a
;; hash-pinned URL is fetched + sha256-verified ON THE HOST (network/fs
;; allowed there, before any sandbox), and the verified file is placed in the
;; build dir so the tier2 build runs OFFLINE (the sandbox unshares the network
;; namespace).  Two assertions:
;;   POSITIVE: correct sha256 -> source fetched + verified on host, built
;;             offline in the sandbox, binary exits 42.
;;   NEGATIVE: wrong sha256 -> `nelix-fetch-source' rejects loudly, no build.
;; The source is a local file served via a file:// URL so the smoke is
;; deterministic (no internet dependency) while still driving the real
;; fetch + verify code path.

;;; Code:

(require 'nelix-registry)
(require 'nelix-builder)
(require 'nelix-sandbox)
(require 'nelix-fetch)

(defvar nsf--failures 0)

(defun nsf-log (fmt &rest args)
  (princ (apply #'format fmt args)) (princ "\n"))

(defun nsf-fail (fmt &rest args)
  (setq nsf--failures (1+ nsf--failures))
  (nsf-log (concat "smoke-sandbox-fod: FAIL: " (apply #'format fmt args))))

(defun nsf--write-fixture (file name url sha)
  "Write a hello-fod source-build recipe FILE named NAME using URL + SHA."
  ;; Emit a QUOTED-LITERAL recipe: `nelix-registry--load-file' reads the
  ;; `nelix-package' call without evaluating it, so :systems must be a literal
  ;; '(...) form (not `(list ...)') -- matching the other fixtures.
  (with-temp-file file
    (insert
     (format
      (concat
       "(require 'nelix-registry)\n"
       "(nelix-package\n"
       " :name %S\n"
       " :version \"1.0.0\"\n"
       " :class 'source-build\n"
       " :description \"fixed-output: host fetch+verify, offline build\"\n"
       " :systems\n"
       " '((x86_64-linux\n"
       "    :source (:type url :url %S :sha256 %S)\n"
       "    :install (:type build\n"
       "              :build-system trivial\n"
       "              :build-phases\n"
       "              ((build . \"cc -O2 hello-fod.c -o hello-fod\")\n"
       "               (install . \"mkdir -p \\\"$out/bin\\\" && cp hello-fod \\\"$out/bin/hello-fod\\\"\"))\n"
       "              :bin (\"bin/hello-fod\")))))\n")
      name url sha))))

(unless (nelix-sandbox-available-p 'bwrap)
  (nsf-log "smoke-sandbox-fod: SKIP — bwrap / unprivileged userns unavailable")
  (kill-emacs 0))

(let* ((tmp (make-temp-file "nsf-" t))
       (srcdir (expand-file-name "src" tmp))
       (srcfile (expand-file-name "hello-fod.c" srcdir)))
  (setq nelix-store-root (expand-file-name "store" tmp)
        nelix-profile-root (expand-file-name "profiles" tmp))
  (make-directory srcdir t)
  (with-temp-file srcfile (insert "int main(){return 42;}\n"))
  (let* ((sha (nelix-fetch-sha256-file srcfile))
         (url (concat "file://" srcfile))
         (good-fx (expand-file-name "hello-fod.el" tmp))
         (bad-fx (expand-file-name "hello-fod-bad.el" tmp))
         (bad-sha "sha256-0000000000000000000000000000000000000000000000000000000000000000"))
    (nsf-log "source file=%s" srcfile)
    (nsf-log "source sha256=%s" sha)
    (nsf--write-fixture good-fx "hello-fod" url sha)
    (nsf--write-fixture bad-fx "hello-fod-bad" url bad-sha)
    (nelix-registry--load-file good-fx)
    (nelix-registry--load-file bad-fx)

    ;; POSITIVE — correct hash, fetched+verified on host, built offline.
    (condition-case e
        (let* ((nelix-builder-hermeticity 'tier2)
               (report (nelix-native-install-recipe
                        (nelix-registry-get "hello-fod") "default" 'x86_64-linux))
               (store-path (plist-get report :store-path))
               (bin (expand-file-name "bin/hello-fod" store-path)))
          (nsf-log "positive: store-path=%s" store-path)
          (if (file-exists-p bin)
              (let ((rc (call-process bin nil nil nil)))
                (if (eq rc 42)
                    (nsf-log (concat "POSITIVE OK: fixed-output source fetched + verified on "
                                     "host, built OFFLINE in the sandbox, exit 42"))
                  (nsf-fail "positive: binary exit %S (expected 42)" rc)))
            (nsf-fail "positive: binary not found at %s" bin)))
      (error (nsf-fail "positive: build errored: %s" (error-message-string e))))

    ;; NEGATIVE — wrong hash must be rejected loudly (no build).
    (let ((failed nil))
      (condition-case e
          (let ((nelix-builder-hermeticity 'tier2))
            (nelix-native-install-recipe
             (nelix-registry-get "hello-fod-bad") "default" 'x86_64-linux))
        (error
         (setq failed t)
         (nsf-log "negative: wrong-hash build rejected: %s"
                  (let ((m (error-message-string e)))
                    (substring m 0 (min 150 (length m)))))))
      (if failed
          (nsf-log "NEGATIVE OK: wrong sha256 rejected loudly before building")
        (nsf-fail "negative: wrong sha256 was NOT rejected")))))

(if (eq nsf--failures 0)
    (nsf-log (concat "smoke-sandbox-fod: SUCCESS — fixed-output fetch "
                     "(host verify -> offline sandbox build) + wrong-hash loud reject, no nix"))
  (progn
    (nsf-log "smoke-sandbox-fod: FAILURE (%d check(s) failed)" nsf--failures)
    (kill-emacs 1)))

;;; nelix-sandbox-fod-smoke.el ends here
