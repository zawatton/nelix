;;; anvil-pkg-compat-test.el --- ERT tests for anvil-pkg-compat -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task D coverage for the runtime-aware compat
;; primitives.  Tests do NOT touch the real `nix' binary or attempt
;; cross-runtime spawns — they exercise the dispatch via `cl-letf'
;; on `anvil-pkg-compat-runtime'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url)            ; Phase 4-G: ensure url-retrieve-synchronously is
                          ; a real defun before cl-letf wraps it; otherwise
                          ; the autoload trigger inside http-get-emacs
                          ; overwrites our mock.
(require 'anvil-pkg-compat)

;;;; --- compat-make-process-async (Phase 4-C L22) ---------------------------

(ert-deftest anvil-pkg-compat-test-make-process-async-on-nelisp-rejects ()
  "compat-make-process-async signals anvil-pkg-async-not-supported on NeLisp.
Verifies the runtime branch in the compat layer (not in
`anvil-pkg.el') is the rejection point."
  (cl-letf (((symbol-function 'anvil-pkg-compat-runtime)
             (lambda () 'nelisp)))
    (should-error (anvil-pkg-compat-make-process-async
                   :name "anvil-pkg-compat-test-rejects"
                   :command '("true")
                   :sentinel #'ignore)
                  :type 'anvil-pkg-async-not-supported)))

(ert-deftest anvil-pkg-compat-test-make-process-async-emacs-passthrough ()
  "compat-make-process-async on Emacs returns a real process object.
Spawns `true' so the test does not depend on any external state;
waits via `accept-process-output' so the process is reaped before
the test exits (no resource leak)."
  ;; Default runtime detection on Emacs returns 'emacs; do not stub.
  (let ((proc (anvil-pkg-compat-make-process-async
               :name "anvil-pkg-compat-test-passthrough"
               :command '("true")
               :noquery t
               :sentinel #'ignore)))
    (should (processp proc))
    (let ((deadline (+ (float-time) 5)))
      (while (and (memq (process-status proc) '(run))
                  (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (should (memq (process-status proc) '(exit signal)))
    (should (eq 0 (process-exit-status proc)))))

;;;; --- Phase 4-G: credentials + masking + http-get auth header --------------

(defmacro anvil-pkg-compat-test--with-env (bindings &rest body)
  "Evaluate BODY with BINDINGS env vars set; restore on exit.
BINDINGS is a list of (NAME VALUE) pairs.  VALUE nil unsets."
  (declare (indent 1))
  `(let ((anvil-pkg-compat-test--saved
          (mapcar (lambda (b) (cons (car b) (getenv (car b))))
                  ',bindings)))
     (unwind-protect
         (progn
           ,@(mapcar (lambda (b) `(setenv ,(car b) ,(cadr b)))
                     bindings)
           ,@body)
       (dolist (s anvil-pkg-compat-test--saved)
         (setenv (car s) (cdr s))))))

(ert-deftest anvil-pkg-compat-test-credential-for-url-github-uses-github-token ()
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" "ghp_aaa")
                                    ("GH_TOKEN" nil))
    (should (equal "Bearer ghp_aaa"
                   (anvil-pkg-compat-credential-for-url
                    "https://github.com/owner/repo")))))

(ert-deftest anvil-pkg-compat-test-credential-for-url-fallback-to-gh-token ()
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" nil)
                                    ("GH_TOKEN" "gho_bbb"))
    (should (equal "Bearer gho_bbb"
                   (anvil-pkg-compat-credential-for-url
                    "https://raw.githubusercontent.com/owner/repo/HEAD/x.el")))))

(ert-deftest anvil-pkg-compat-test-credential-for-url-no-env-returns-nil ()
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil))
    (should-not (anvil-pkg-compat-credential-for-url
                 "https://github.com/owner/repo"))))

(ert-deftest anvil-pkg-compat-test-credential-for-url-unknown-host-returns-nil ()
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" "ghp_zzz"))
    (should-not (anvil-pkg-compat-credential-for-url
                 "https://example.com/x"))))

(ert-deftest anvil-pkg-compat-test-credential-for-url-empty-token-skipped ()
  "Empty env var must not produce a Bearer header."
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" "") ("GH_TOKEN" nil))
    (should-not (anvil-pkg-compat-credential-for-url
                 "https://github.com/owner/repo"))))

(ert-deftest anvil-pkg-compat-test-mask-credentials-redacts-bearer ()
  (should (equal "before Bearer *** after"
                 (anvil-pkg-compat-mask-credentials
                  "before Bearer ghp_xyz123 after"))))

(ert-deftest anvil-pkg-compat-test-mask-credentials-redacts-extra-access-tokens ()
  (let ((masked (anvil-pkg-compat-mask-credentials
                 "--option extra-access-tokens \"github.com=ghp_xyz\"")))
    (should (string-match-p "github.com=\\*\\*\\*" masked))
    (should-not (string-match-p "ghp_xyz" masked))))

(ert-deftest anvil-pkg-compat-test-mask-credentials-redacts-x-access-token ()
  (should (equal "https://x-access-token:***@github.com/owner/repo"
                 (anvil-pkg-compat-mask-credentials
                  "https://x-access-token:ghp_xyz@github.com/owner/repo"))))

(ert-deftest anvil-pkg-compat-test-mask-credentials-leaves-clean-strings ()
  (let ((s "no secrets here"))
    (should (equal s (anvil-pkg-compat-mask-credentials s)))))

(ert-deftest anvil-pkg-compat-test-http-get-injects-auth-header-from-env ()
  "When GITHUB_TOKEN is set, host-based lookup injects Authorization."
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" "ghp_xyz") ("GH_TOKEN" nil))
    (let ((seen-headers nil))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (anvil-pkg-compat-http-get "https://github.com/owner/repo")
        (should (assoc "Authorization" seen-headers))
        (should (equal "Bearer ghp_xyz"
                       (cdr (assoc "Authorization" seen-headers))))))))

(ert-deftest anvil-pkg-compat-test-http-get-no-env-no-header ()
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil))
    (let ((seen-headers t))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (anvil-pkg-compat-http-get "https://github.com/owner/repo")
        (should-not (assoc "Authorization" seen-headers))))))

(ert-deftest anvil-pkg-compat-test-http-get-explicit-auth-header-overrides-env ()
  "Explicit AUTH-HEADER arg wins over env-var auto-detect."
  (anvil-pkg-compat-test--with-env (("GITHUB_TOKEN" "from_env"))
    (let ((seen-headers nil))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (anvil-pkg-compat-http-get
         "https://github.com/owner/repo" 5 "Bearer explicit_value")
        (should (equal "Bearer explicit_value"
                       (cdr (assoc "Authorization" seen-headers))))))))

(provide 'anvil-pkg-compat-test)
;;; anvil-pkg-compat-test.el ends here
