;;; anvil-pkg-test.el --- ERT tests for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 1 ERT coverage for the public API.  All tests mock
;; `anvil-pkg--call-nix-fn' so no nix binary is required to run them.
;;
;; Run with:
;;   make test
;; or directly:
;;   emacs -Q --batch -L . -L test -l ert -l test/anvil-pkg-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg)

(defmacro anvil-pkg-test--with-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `anvil-pkg--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default)."
  (declare (indent 1))
  `(let ((anvil-pkg--call-nix-fn ,mock-fn)
         (anvil-pkg-nix-channel "nixpkgs")
         (anvil-pkg-profile-dir "/tmp/anvil-pkg-test-profile"))
     ,@body))

;;;; --- install ---------------------------------------------------------------

(ert-deftest anvil-pkg-test-install-happy ()
  "anvil-pkg-install returns t and forwards correct args on nix exit 0."
  (let (captured-args)
    (anvil-pkg-test--with-mock
        (lambda (args)
          (setq captured-args args)
          (list :exit 0 :stdout "" :stderr ""))
      (should (eq t (pkg-install "ripgrep"))))
    (should (member "profile" captured-args))
    (should (member "install" captured-args))
    (should (member "nixpkgs#ripgrep" captured-args))
    (should (member "--profile" captured-args))))

(ert-deftest anvil-pkg-test-install-error ()
  "anvil-pkg-install signals anvil-pkg-nix-failed on non-zero exit, with stderr."
  (anvil-pkg-test--with-mock
      (lambda (_args)
        (list :exit 1
              :stdout ""
              :stderr "error: cannot resolve flake reference 'nixpkgs#nope'\n"))
    (let ((err (should-error (pkg-install "nope")
                             :type 'anvil-pkg-nix-failed)))
      (should (string-match-p "cannot resolve" (cadr err))))))

;;;; --- search ----------------------------------------------------------------

(ert-deftest anvil-pkg-test-search-happy ()
  "anvil-pkg-search parses JSON into plists with :name / :version / :description."
  (anvil-pkg-test--with-mock
      (lambda (args)
        (should (member "search" args))
        (should (member "ripgrep" args))
        (should (member "--json" args))
        (list :exit 0
              :stdout (concat
                       "{"
                       "\"legacyPackages.x86_64-linux.ripgrep\":"
                       "{\"pname\":\"ripgrep\","
                       "\"version\":\"13.0.0\","
                       "\"description\":\"A line-oriented search tool\"}"
                       "}")
              :stderr ""))
    (let* ((res (pkg-search "ripgrep"))
           (row (car res)))
      (should (= 1 (length res)))
      (should (equal "ripgrep" (plist-get row :name)))
      (should (equal "13.0.0" (plist-get row :version)))
      (should (equal "A line-oriented search tool"
                     (plist-get row :description)))
      (should (string-match-p "ripgrep$" (plist-get row :attrpath))))))

(ert-deftest anvil-pkg-test-search-empty ()
  "anvil-pkg-search returns nil when nix returns an empty object."
  (anvil-pkg-test--with-mock
      (lambda (_args) (list :exit 0 :stdout "{}" :stderr ""))
    (should (null (pkg-search "no-such-pkg-xyzzy")))))

;;;; --- list ------------------------------------------------------------------

(ert-deftest anvil-pkg-test-list-happy ()
  "anvil-pkg-list parses Nix 2.18 modern profile JSON."
  (anvil-pkg-test--with-mock
      (lambda (args)
        (should (member "profile" args))
        (should (member "list" args))
        (should (member "--json" args))
        (should (member "--profile" args))
        (list :exit 0
              :stdout (concat
                       "{\"version\":3,"
                       "\"elements\":{"
                       "\"ripgrep\":{"
                       "\"active\":true,"
                       "\"attrPath\":\"ripgrep\","
                       "\"originalUrl\":\"flake:nixpkgs\","
                       "\"storePaths\":[\"/nix/store/abc-ripgrep-13.0.0\"]"
                       "}"
                       "}}")
              :stderr ""))
    (let* ((res (pkg-list))
           (row (car res)))
      (should (= 1 (length res)))
      (should (equal "ripgrep" (plist-get row :name)))
      (should (equal "ripgrep" (plist-get row :attr-path)))
      (should (equal "flake:nixpkgs" (plist-get row :original-url)))
      (should (member "/nix/store/abc-ripgrep-13.0.0"
                      (plist-get row :store-paths))))))

(ert-deftest anvil-pkg-test-list-empty ()
  "anvil-pkg-list returns nil for a fresh, empty profile."
  (anvil-pkg-test--with-mock
      (lambda (_args)
        (list :exit 0
              :stdout "{\"version\":3,\"elements\":{}}"
              :stderr ""))
    (should (null (pkg-list)))))

(ert-deftest anvil-pkg-test-install-emacs-package-augments-load-path ()
  "pkg-install adds the installed emacs-package site-lisp dir to `load-path'."
  (require 'anvil-pkg-dsl)
  (let* ((store-root "/tmp/anvil-pkg-test/fakestore/foo-store")
         (site-lisp-dir (expand-file-name "share/emacs/site-lisp/foo" store-root))
         (flake-path "/tmp/anvil-pkg-test/flake.nix")
         (load-path (copy-sequence load-path)))
    (unwind-protect
        (progn
          (anvil-pkg--registry-clear)
          (if (and (boundp 'anvil-pkg--known-build-systems)
                   (memq 'emacs-package anvil-pkg--known-build-systems))
              (eval '(pkg-define foo
                       (version "1.0.0")
                       (source (url-fetch "https://example.invalid/foo.tar.gz"
                                          :sha256 "sha256-foo"))
                       (build-system emacs-package))
                    t)
            (anvil-pkg--register
             'foo
             '(:name foo
               :version "1.0.0"
               :source (:type url-fetch
                        :url "https://example.invalid/foo.tar.gz"
                        :sha256 "sha256-foo")
               :build-system (:type emacs-package)
               :inputs nil
               :native-inputs nil)))
          (anvil-pkg-compat-make-directory site-lisp-dir t)
          (let ((anvil-pkg--write-flake-fn (lambda () flake-path)))
            (anvil-pkg-test--with-mock
                (lambda (args)
                  (cond
                   ((and (member "profile" args)
                         (member "install" args))
                    (list :exit 0 :stdout "" :stderr ""))
                   ((and (member "profile" args)
                         (member "list" args)
                         (member "--json" args))
                    (list :exit 0
                          :stdout (concat
                                   "{\"version\":3,"
                                   "\"elements\":{"
                                   "\"foo\":{"
                                   "\"active\":true,"
                                   "\"attrPath\":\"foo\","
                                   "\"originalUrl\":\"path:/tmp/anvil-pkg-test#foo\","
                                   "\"storePaths\":[\""
                                   store-root
                                   "\"]"
                                   "}"
                                   "}}")
                          :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              (should (eq t (pkg-install 'foo)))
              (should (member site-lisp-dir load-path)))))
      (anvil-pkg--registry-clear)
      (when (file-exists-p "/tmp/anvil-pkg-test")
        (delete-directory "/tmp/anvil-pkg-test" t)))))

;;;; --- Phase 4-B sub-task C: :async pkg-install -----------------------------
;; The async path uses `make-process' under the hood.  Tests intercept
;; `anvil-pkg--make-process-fn' and substitute a `true' / `sh -c
;; 'exit 1'' real process so the production sentinel runs against a
;; live process object (which is required for `process-get' /
;; `process-put' / `process-status' to behave correctly).  We then
;; spin `accept-process-output' until the sentinel has fired.

(defun anvil-pkg-test--wait-until (predicate &optional timeout)
  "Pump `accept-process-output' until PREDICATE returns non-nil.
TIMEOUT defaults to 5 seconds; raises an ERT failure on overrun."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate)
      (ert-fail (format "anvil-pkg-test: predicate %S never became non-nil"
                        predicate)))))

(ert-deftest anvil-pkg-test-install-async-happy-runs-on-success ()
  "pkg-install :async t routes a clean exit through :on-success.

Mocks `anvil-pkg--make-process-fn' to spawn `true' (exit 0) while
preserving the production sentinel + stderr-buffer plumbing.  The
real process gives us correct `process-status' / `process-get'
behaviour; the test waits via `accept-process-output' until the
sentinel has set a captured-flag."
  (let* ((captured nil)
         (make-process-orig (symbol-function 'make-process))
         (anvil-pkg--make-process-fn
          (lambda (&rest plist)
            ;; Replace :command with `true' so the real process exits 0
            ;; immediately; keep :sentinel / :stderr / :name / :noquery
            ;; / :connection-type as supplied by production code.
            (let ((replaced (copy-sequence plist)))
              (setq replaced (plist-put replaced :command (list "true")))
              (apply make-process-orig replaced)))))
    (anvil-pkg-test--with-mock
        (lambda (_args)
          ;; :ensure-nix path bypasses executable-find when the mock
          ;; is installed; this branch should not be hit on :async,
          ;; but supply a benign return for safety.
          (list :exit 0 :stdout "" :stderr ""))
      (let ((proc (pkg-install "ripgrep"
                               :async t
                               :on-success
                               (lambda (result) (setq captured result))
                               :on-error
                               (lambda (err)
                                 (ert-fail
                                  (format ":on-error fired unexpectedly: %S" err))))))
        (should (processp proc))
        (anvil-pkg-test--wait-until (lambda () captured))
        (should (eq :installed (plist-get captured :status)))
        (should (equal "ripgrep" (plist-get captured :name)))))))

(ert-deftest anvil-pkg-test-install-async-error-routes-to-on-error ()
  "pkg-install :async t routes a non-zero exit through :on-error.
Stderr accumulated by the production code's `:stderr' buffer is
visible in the error plist's :stderr field.  :on-success must NOT
fire."
  (let* ((captured-err nil)
         (success-fired nil)
         (make-process-orig (symbol-function 'make-process))
         (anvil-pkg--make-process-fn
          (lambda (&rest plist)
            (let ((replaced (copy-sequence plist)))
              (setq replaced
                    (plist-put replaced :command
                               (list "sh" "-c"
                                     "printf 'error: cannot resolve flake reference' >&2; exit 1")))
              (apply make-process-orig replaced)))))
    (anvil-pkg-test--with-mock
        (lambda (_args)
          (list :exit 0 :stdout "" :stderr ""))
      (let ((proc (pkg-install "nope"
                               :async t
                               :on-success
                               (lambda (_r) (setq success-fired t))
                               :on-error
                               (lambda (err) (setq captured-err err)))))
        (should (processp proc))
        (anvil-pkg-test--wait-until (lambda () captured-err))
        (should (null success-fired))
        (should (numberp (plist-get captured-err :exit)))
        (should (not (eq 0 (plist-get captured-err :exit))))
        (should (equal "nope" (plist-get captured-err :name)))
        (should (eq 'anvil-pkg-nix-failed (plist-get captured-err :error)))
        (should (string-match-p "cannot resolve"
                                (or (plist-get captured-err :stderr) "")))))))

(ert-deftest anvil-pkg-test-install-async-on-nelisp-rejects ()
  "pkg-install :async t signals on the NeLisp runtime.
`anvil-pkg-compat-runtime' is the sole branching authority; this
test forces it to return `nelisp' and verifies the spawn helper
refuses to call `make-process'."
  (cl-letf (((symbol-function 'anvil-pkg-compat-runtime)
             (lambda () 'nelisp))
            ;; Should never be consulted, but stub for safety.
            (anvil-pkg--make-process-fn
             (lambda (&rest _)
               (ert-fail ":make-process-fn invoked under NeLisp runtime"))))
    (anvil-pkg-test--with-mock
        (lambda (_args)
          (list :exit 0 :stdout "" :stderr ""))
      (should-error (pkg-install "ripgrep" :async t)
                    :type 'anvil-pkg-async-not-supported))))

(provide 'anvil-pkg-test)
;;; anvil-pkg-test.el ends here
