;;; nelix-core-test.el --- ERT tests for nelix-core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 1 ERT coverage for the public API.  All tests mock
;; `nelix-core--call-nix-fn' so no nix binary is required to run them.
;;
;; Run with:
;;   make test
;; or directly:
;;   emacs -Q --batch -L . -L test -l ert -l test/nelix-core-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-state)

(defvar nelix-core--write-flake-fn)

(declare-function nelix-core--render-flake "nelix-dsl")
(declare-function nelix-core--register "nelix-dsl")
(declare-function nelix-core--registry-clear "nelix-dsl")

(defmacro nelix-core-test--with-mock (mock-fn &rest body)
  "Run BODY with `nelix-core--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `nelix-core--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default).

Pre-seeds the persistent state with a sentinel pre-2.34 Nix
version so install-path tests that don't anticipate a `nix
--version' call in their mock cond do not regress on Phase 4-C
L20.  Tests that care about the dispatch overwrite the cache
themselves via `nelix-state-put'.

The state file is bound to a tmp path so the real
~/.local/state/nelix/state.json is never touched and the
in-process state cache is reset between tests."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "nelix-core-test-" nil ".json"))
          (nelix-state-file tmp)
          (nelix-state--cache 'unloaded)
          (nelix-state--loaded-from nil)
          (nelix-compat--nelisp-runtime-p nil)
          (nelix-core--call-nix-fn ,mock-fn)
          (nelix-core-nix-channel "nixpkgs")
          (nelix-core-profile-dir "/tmp/nelix-core-test-profile"))
     (unwind-protect
         (progn
           (delete-file tmp)
           (nelix-state-put nelix-core--nix-version-namespace
                                nelix-core--nix-version-key
                                "2.18.0")
           ,@body)
       (when (file-exists-p tmp) (delete-file tmp)))))

;;;; --- defaults ---------------------------------------------------------------

(ert-deftest nelix-core-test-default-profile-dir-is-nelix ()
  "The product default profile lives under ~/.local/state/nelix."
  (let ((expected (expand-file-name
                   "nelix/profile"
                   (or (nelix-compat-getenv "XDG_STATE_HOME")
                       (expand-file-name ".local/state"
                                         (or (nelix-compat-getenv "HOME")
                                             "~"))))))
    (should (equal (expand-file-name nelix-core-profile-dir)
                   expected))
    (should-not (string-match-p (regexp-quote "nelix-core/profile")
                                nelix-core-profile-dir))))

;;;; --- install ---------------------------------------------------------------

(ert-deftest nelix-core-test-install-happy ()
  "nelix-core-install returns t and forwards correct args on nix exit 0."
  (let (captured-args)
    (nelix-core-test--with-mock
        (lambda (args)
          (setq captured-args args)
          (list :exit 0 :stdout "" :stderr ""))
      (should (eq t (pkg-install "ripgrep"))))
    (should (member "profile" captured-args))
    (should (member "install" captured-args))
    (should (member "nixpkgs#ripgrep" captured-args))
    (should (member "--profile" captured-args))))

(ert-deftest nelix-core-test-install-error ()
  "nelix-core-install signals nelix-nix-failed on non-zero exit, with stderr."
  (nelix-core-test--with-mock
      (lambda (_args)
        (list :exit 1
              :stdout ""
              :stderr "error: cannot resolve flake reference 'nixpkgs#nope'\n"))
    (let ((err (should-error (pkg-install "nope")
                             :type 'nelix-nix-failed)))
      (should (string-match-p "cannot resolve" (cadr err))))))

;;;; --- search ----------------------------------------------------------------

(ert-deftest nelix-core-test-search-happy ()
  "nelix-core-search parses JSON into plists with :name / :version / :description."
  (nelix-core-test--with-mock
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

(ert-deftest nelix-core-test-search-empty ()
  "nelix-core-search returns nil when nix returns an empty object."
  (nelix-core-test--with-mock
      (lambda (_args) (list :exit 0 :stdout "{}" :stderr ""))
    (should (null (pkg-search "no-such-pkg-xyzzy")))))

;;;; --- list ------------------------------------------------------------------

(ert-deftest nelix-core-test-list-happy ()
  "nelix-core-list parses Nix 2.18 modern profile JSON."
  (nelix-core-test--with-mock
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

(ert-deftest nelix-core-test-list-empty ()
  "nelix-core-list returns nil for a fresh, empty profile."
  (nelix-core-test--with-mock
      (lambda (_args)
        (list :exit 0
              :stdout "{\"version\":3,\"elements\":{}}"
              :stderr ""))
    (should (null (pkg-list)))))

(ert-deftest nelix-core-test-install-emacs-package-augments-load-path ()
  "pkg-install adds the installed emacs-package site-lisp dir to `load-path'."
  (require 'nelix-dsl)
  (let* ((store-root "/tmp/nelix-core-test/fakestore/foo-store")
         (site-lisp-dir (expand-file-name "share/emacs/site-lisp/foo" store-root))
         (flake-path "/tmp/nelix-core-test/flake.nix")
         (load-path (copy-sequence load-path)))
    (unwind-protect
        (progn
          (nelix-core--registry-clear)
          (if (and (boundp 'nelix-core--known-build-systems)
                   (memq 'emacs-package nelix-core--known-build-systems))
              (eval '(pkg-define foo
                       (version "1.0.0")
                       (source (url-fetch "https://example.invalid/foo.tar.gz"
                                          :sha256 "sha256-foo"))
                       (build-system emacs-package))
                    t)
            (nelix-core--register
             'foo
             '(:name foo
               :version "1.0.0"
               :source (:type url-fetch
                        :url "https://example.invalid/foo.tar.gz"
                        :sha256 "sha256-foo")
               :build-system (:type emacs-package)
               :inputs nil
               :native-inputs nil)))
          (nelix-compat-make-directory site-lisp-dir t)
          (let ((nelix-core--write-flake-fn (lambda () flake-path)))
            (nelix-core-test--with-mock
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
                                   "\"originalUrl\":\"path:/tmp/nelix-core-test#foo\","
                                   "\"storePaths\":[\""
                                   store-root
                                   "\"]"
                                   "}"
                                   "}}")
                          :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              (should (eq t (pkg-install 'foo)))
              (should (member site-lisp-dir load-path)))))
      (nelix-core--registry-clear)
      (when (file-exists-p "/tmp/nelix-core-test")
        (delete-directory "/tmp/nelix-core-test" t)))))

(ert-deftest nelix-core-test-install-emacs-package-flat-layout ()
  "pkg-install adds the flat site-lisp dir for the trivialBuild flat layout.
Regression for the gcmh real-Nix install where
$out/share/emacs/site-lisp/<pname>.el sits directly in the flat
dir with no per-package subdir (commit 7c466b6 follow-up)."
  (require 'nelix-dsl)
  (let* ((store-root "/tmp/nelix-core-test/fakestore-flat/bar-store")
         (flat-dir (expand-file-name "share/emacs/site-lisp" store-root))
         (flat-el  (expand-file-name "bar.el" flat-dir))
         (flake-path "/tmp/nelix-core-test/flake.nix")
         (load-path (copy-sequence load-path)))
    (unwind-protect
        (progn
          (nelix-core--registry-clear)
          (nelix-core--register
           'bar
           '(:name bar
             :version "1.0.0"
             :source (:type url-fetch
                      :url "https://example.invalid/bar.tar.gz"
                      :sha256 "sha256-bar")
             :build-system (:type emacs-package)
             :inputs nil
             :native-inputs nil))
          (nelix-compat-make-directory flat-dir t)
          (with-temp-file flat-el (insert ";; bar.el placeholder\n"))
          (let ((nelix-core--write-flake-fn (lambda () flake-path)))
            (nelix-core-test--with-mock
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
                                   "\"bar\":{"
                                   "\"active\":true,"
                                   "\"attrPath\":\"bar\","
                                   "\"originalUrl\":\"path:/tmp/nelix-core-test#bar\","
                                   "\"storePaths\":[\""
                                   store-root
                                   "\"]"
                                   "}"
                                   "}}")
                          :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              (should (eq t (pkg-install 'bar)))
              (should (member flat-dir load-path))
              ;; Per-package dir was never created; ensure the hook did
              ;; not fall back to it.
              (should-not (member (expand-file-name "bar" flat-dir)
                                  load-path)))))
      (nelix-core--registry-clear)
      (when (file-exists-p "/tmp/nelix-core-test")
        (delete-directory "/tmp/nelix-core-test" t)))))

(ert-deftest nelix-core-test-install-emacs-package-elpa-style-layout ()
  "pkg-install adds the elpa subdir for the melpaBuild elpa-style layout.
Mocks $out/share/emacs/site-lisp/elpa/<pname>-<ver>/ and verifies
the version-suffixed directory itself is what lands on
`load-path' (commit 7c466b6 follow-up)."
  (require 'nelix-dsl)
  (let* ((store-root "/tmp/nelix-core-test/fakestore-elpa/baz-store")
         (flat-dir (expand-file-name "share/emacs/site-lisp" store-root))
         (elpa-subdir (expand-file-name "elpa/baz-1.2.3" flat-dir))
         (flake-path "/tmp/nelix-core-test/flake.nix")
         (load-path (copy-sequence load-path)))
    (unwind-protect
        (progn
          (nelix-core--registry-clear)
          (nelix-core--register
           'baz
           '(:name baz
             :version "1.2.3"
             :source (:type url-fetch
                      :url "https://example.invalid/baz.tar.gz"
                      :sha256 "sha256-baz")
             :build-system (:type emacs-package)
             :inputs nil
             :native-inputs nil))
          (nelix-compat-make-directory elpa-subdir t)
          (let ((nelix-core--write-flake-fn (lambda () flake-path)))
            (nelix-core-test--with-mock
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
                                   "\"baz\":{"
                                   "\"active\":true,"
                                   "\"attrPath\":\"baz\","
                                   "\"originalUrl\":\"path:/tmp/nelix-core-test#baz\","
                                   "\"storePaths\":[\""
                                   store-root
                                   "\"]"
                                   "}"
                                   "}}")
                          :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              (should (eq t (pkg-install 'baz)))
              (should (member elpa-subdir load-path))
              ;; Neither the per-package nor the bare flat dir should win
              ;; when only the elpa subdir exists.
              (should-not (member (expand-file-name "baz" flat-dir)
                                  load-path))
              (should-not (member flat-dir load-path)))))
      (nelix-core--registry-clear)
      (when (file-exists-p "/tmp/nelix-core-test")
        (delete-directory "/tmp/nelix-core-test" t)))))

(ert-deftest nelix-core-test-install-emacs-package-elpa-style-layout-pname ()
  "pkg-install uses emacs-package :pname for elpa-style load-path lookup.
The Nix profile element can be named `emacs-async' while the
installed elpa directory is `async-<version>'."
  (require 'nelix-dsl)
  (let* ((store-root "/tmp/nelix-core-test/fakestore-pname/async-store")
         (flat-dir (expand-file-name "share/emacs/site-lisp" store-root))
         (elpa-subdir (expand-file-name "elpa/async-0.0.0" flat-dir))
         (flake-path "/tmp/nelix-core-test/flake.nix")
         (load-path (copy-sequence load-path)))
    (unwind-protect
        (progn
          (nelix-core--registry-clear)
          (nelix-core--register
           'emacs-async
           '(:name emacs-async
             :version "0.0.0"
             :source (:type url-fetch
                      :url "https://example.invalid/async.tar.gz"
                      :sha256 "sha256-async")
             :build-system (:type emacs-package :pname "async")
             :inputs nil
             :native-inputs nil))
          (nelix-compat-make-directory elpa-subdir t)
          (let ((nelix-core--write-flake-fn (lambda () flake-path)))
            (nelix-core-test--with-mock
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
                                   "\"emacs-async\":{"
                                   "\"active\":true,"
                                   "\"attrPath\":\"emacs-async\","
                                   "\"originalUrl\":\"path:/tmp/nelix-core-test#emacs-async\","
                                   "\"storePaths\":[\""
                                   store-root
                                   "\"]"
                                   "}"
                                   "}}")
                          :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              (should (eq t (pkg-install 'emacs-async)))
              (should (member elpa-subdir load-path))
              (should-not (member (expand-file-name "emacs-async" flat-dir)
                                  load-path))
              (should-not (member (expand-file-name "elpa/emacs-async-0.0.0" flat-dir)
                                  load-path)))))
      (nelix-core--registry-clear)
      (when (file-exists-p "/tmp/nelix-core-test")
        (delete-directory "/tmp/nelix-core-test" t)))))

;;;; --- Phase 4-B sub-task C: :async pkg-install -----------------------------
;; The async path uses `make-process' under the hood.  Tests intercept
;; `nelix-core--make-process-fn' and substitute a `true' / `sh -c
;; 'exit 1'' real process so the production sentinel runs against a
;; live process object (which is required for `process-get' /
;; `process-put' / `process-status' to behave correctly).  We then
;; spin `accept-process-output' until the sentinel has fired.

(defun nelix-core-test--wait-until (predicate &optional timeout)
  "Pump `accept-process-output' until PREDICATE returns non-nil.
TIMEOUT defaults to 5 seconds; raises an ERT failure on overrun."
  (let ((deadline (+ (float-time) (or timeout 5))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate)
      (ert-fail (format "nelix-core-test: predicate %S never became non-nil"
                        predicate)))))

(ert-deftest nelix-core-test-install-async-happy-runs-on-success ()
  "pkg-install :async t routes a clean exit through :on-success.

Mocks `nelix-compat-make-process-async' (Phase 4-C L22 seam)
to spawn `true' (exit 0) while preserving the production sentinel
+ stderr-buffer plumbing.  The real process gives us correct
`process-status' / `process-get' behaviour; the test waits via
`accept-process-output' until the sentinel has set a captured flag."
  (let* ((captured nil)
         (make-process-orig (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'nelix-compat-make-process-async)
               (lambda (&rest plist)
                 ;; Replace :command with `true' so the real process exits 0
                 ;; immediately; keep :sentinel / :stderr / :name / :noquery
                 ;; / :connection-type as supplied by production code.
                 (let ((replaced (copy-sequence plist)))
                   (setq replaced (plist-put replaced :command (list "true")))
                   (apply make-process-orig replaced)))))
      (nelix-core-test--with-mock
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
          (nelix-core-test--wait-until (lambda () captured))
          (should (eq :installed (plist-get captured :status)))
          (should (equal "ripgrep" (plist-get captured :name))))))))

(ert-deftest nelix-core-test-install-async-error-routes-to-on-error ()
  "pkg-install :async t routes a non-zero exit through :on-error.
Stderr accumulated by the production code's `:stderr' buffer is
visible in the error plist's :stderr field.  :on-success must NOT
fire."
  (let* ((captured-err nil)
         (success-fired nil)
         (make-process-orig (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'nelix-compat-make-process-async)
               (lambda (&rest plist)
                 (let ((replaced (copy-sequence plist)))
                   (setq replaced
                         (plist-put replaced :command
                                    (list "sh" "-c"
                                          "printf 'error: cannot resolve flake reference' >&2; exit 1")))
                   (apply make-process-orig replaced)))))
      (nelix-core-test--with-mock
          (lambda (_args)
            (list :exit 0 :stdout "" :stderr ""))
        (let ((proc (pkg-install "nope"
                                 :async t
                                 :on-success
                                 (lambda (_r) (setq success-fired t))
                                 :on-error
                                 (lambda (err) (setq captured-err err)))))
          (should (processp proc))
          (nelix-core-test--wait-until (lambda () captured-err))
          (should (null success-fired))
          (should (numberp (plist-get captured-err :exit)))
          (should (not (eq 0 (plist-get captured-err :exit))))
          (should (equal "nope" (plist-get captured-err :name)))
          (should (eq 'nelix-nix-failed (plist-get captured-err :error)))
          (should (string-match-p "cannot resolve"
                                  (or (plist-get captured-err :stderr) ""))))))))

(ert-deftest nelix-core-test-install-async-on-nelisp-uses-backend ()
  "pkg-install :async t delegates to the NeLisp async backend.
`nelix-compat-runtime' is the sole branching authority and is
consulted inside `nelix-compat-make-process-async'; this test
forces it to return `nelisp' and verifies the spawn helper uses the
loaded NeLisp backend instead of rejecting async installs."
  (let ((nelix-compat-nelisp-make-process-function
         (lambda (&rest plist)
           (make-process
            :name (or (plist-get plist :name) "nelisp-async-test")
            :command (list "true")
            :noquery t))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp)))
      (nelix-core-test--with-mock
          (lambda (_args)
            (list :exit 0 :stdout "" :stderr ""))
        (let ((proc (pkg-install "ripgrep" :async t)))
          (unwind-protect
              (progn
                (should (processp proc))
                (should (equal "ripgrep"
                               (nelix-compat-process-get
                                proc 'nelix-core--name))))
            (when (processp proc)
              (delete-process proc))))))))

;;;; --- Phase 4-C sub-task B (L19): rollback API ---------------------------

(ert-deftest nelix-core-test-list-generations-parses-history-json ()
  "pkg-list-generations parses `nix profile history --json' output.

Mocks the documented Nix 2.18+ schema (object with a
`generations' array) and verifies each parsed generation carries
:id, :date, :packages, :active in the expected shape, with
ascending order by id."
  (nelix-core-test--with-mock
      (lambda (args)
        (cond
         ((and (member "profile" args)
               (member "history" args)
               (member "--json" args))
          (list :exit 0
                :stdout (concat
                         "{\"generations\":["
                         "{\"id\":4,\"date\":\"2026-05-04T17:30:00Z\","
                         "\"active\":false,"
                         "\"packages\":[\"ripgrep\"]},"
                         "{\"id\":5,\"date\":\"2026-05-04T18:00:00Z\","
                         "\"active\":true,"
                         "\"packages\":[\"ripgrep\",\"magit\"]}"
                         "]}")
                :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let* ((res (pkg-list-generations))
           (g4 (car res))
           (g5 (cadr res)))
      (should (= 2 (length res)))
      ;; ascending id order
      (should (= 4 (plist-get g4 :id)))
      (should (= 5 (plist-get g5 :id)))
      (should (equal "2026-05-04T17:30:00Z" (plist-get g4 :date)))
      (should (equal '(ripgrep) (plist-get g4 :packages)))
      (should (null (plist-get g4 :active)))
      (should (equal '(ripgrep magit) (plist-get g5 :packages)))
      (should (eq t (plist-get g5 :active)))
      ;; cache mirror updated (now persisted via nelix-state)
      (should (equal res (nelix-core--generations-cache-get))))))

(ert-deftest nelix-core-test-rollback-runs-nix-profile-rollback ()
  "pkg-rollback shells out to `nix profile rollback --to-generation N'.

Mock captures rollback invocation arguments and returns an empty
profile for the post-rollback `pkg-list' so the emacs-package
hook re-run is a benign no-op."
  (let ((captured-rollback-args nil))
    (nelix-core-test--with-mock
        (lambda (args)
          (cond
           ((and (member "profile" args)
                 (member "rollback" args))
            (setq captured-rollback-args args)
            (list :exit 0 :stdout "" :stderr ""))
           ;; Cache refresh after rollback.
           ((and (member "profile" args)
                 (member "history" args)
                 (member "--json" args))
            (list :exit 0
                  :stdout "{\"generations\":[]}"
                  :stderr ""))
           ;; Hook re-run pkg-list — empty profile.
           ((and (member "profile" args)
                 (member "list" args)
                 (member "--json" args))
            (list :exit 0
                  :stdout "{\"version\":3,\"elements\":{}}"
                  :stderr ""))
           (t (ert-fail (format "unexpected nix args: %S" args)))))
      ;; Pre-seed the persistent generations mirror.
      (nelix-core--generations-cache-put
       (list (list :id 3 :date "d3" :packages '() :active nil)
             (list :id 4 :date "d4" :packages '() :active t)))
      (should (eq t (pkg-rollback 3)))
      (should (member "rollback" captured-rollback-args))
      (should (member "--to-generation" captured-rollback-args))
      (should (member "3" captured-rollback-args)))))

(ert-deftest nelix-core-test-history-filters-by-package-name ()
  "pkg-history returns events for the requested package only.

Pre-populates the persistent generations mirror with three
generations involving two packages (foo, bar); queries for `foo'
and verifies only foo's :installed / :removed events come back —
bar's lineage stays out of the result."
  (nelix-core-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-history must not shell out when mirror is populated"))
    (nelix-core--generations-cache-put
     (list
      (list :id 1 :date "d1" :packages '(foo)         :active nil)
      (list :id 2 :date "d2" :packages '(foo bar)     :active nil)
      (list :id 3 :date "d3" :packages '(bar)         :active t)))
    (let ((events (pkg-history 'foo)))
      (should (= 2 (length events)))
      ;; First entry: id=1, foo present, prev set uninitialised → :installed
      (should (eq :installed (plist-get (nth 0 events) :event)))
      (should (= 1 (plist-get (nth 0 events) :generation)))
      ;; Second entry: id=3, foo gone → :removed
      (should (eq :removed (plist-get (nth 1 events) :event)))
      (should (= 3 (plist-get (nth 1 events) :generation)))
      ;; bar should NOT appear in foo's history at all.
      (dolist (ev events)
        (should-not (memq 'bar (or (plist-get ev :packages) '())))))))

;;;; --- Phase 4-C sub-task C (L20): Nix profile install dispatch ------------

(ert-deftest nelix-core-test-install-uses-install-on-nix-2-34 ()
  "pkg-install keeps using `install' as the subcommand on Nix >= 2.34.

Pins the persistent Nix-version cache to a 2.34 string inside the
macro body so the detect helper short-circuits without consulting
the mock; verifies the captured args carry the CLI-supported
`install' spelling."
  (let (captured-args)
    (nelix-core-test--with-mock
        (lambda (args)
          (setq captured-args args)
          (list :exit 0 :stdout "" :stderr ""))
      (nelix-state-put nelix-core--nix-version-namespace
                           nelix-core--nix-version-key "2.34.0")
    (should (eq t (pkg-install "ripgrep"))))
    (should (member "profile" captured-args))
    (should (member "install" captured-args))
    (should-not (member "add" captured-args))
    (should (member "nixpkgs#ripgrep" captured-args))))

(ert-deftest nelix-core-test-install-uses-install-on-pre-2-34 ()
  "pkg-install passes `install' on Nix < 2.34.

Pins the persistent Nix-version cache to 2.18.5 (older than 2.34)
inside the macro body and verifies the legacy `install' subcommand
is preserved.  The macro pre-seeds 2.18.0 already, but we overwrite
explicitly so this test does not couple to that default."
  (let (captured-args)
    (nelix-core-test--with-mock
        (lambda (args)
          (setq captured-args args)
          (list :exit 0 :stdout "" :stderr ""))
      (nelix-state-put nelix-core--nix-version-namespace
                           nelix-core--nix-version-key "2.18.5")
      (should (eq t (pkg-install "ripgrep"))))
    (should (member "profile" captured-args))
    (should (member "install" captured-args))
    (should-not (member "add" captured-args))))

;;;; --- Phase 4-D sub-task C (L25): per-package rollback -------------------

(ert-deftest nelix-core-test-rollback-package-happy ()
  "pkg-rollback-package re-renders flake without target pkg + calls nix add.

Pre-seeds the registry with two emacs-package IRs (magit + ripgrep)
and the persistent generations mirror with a single active
generation listing both.  Mocks the flake writer to capture the
rendered Nix expression and the nix invocation to capture argv.
After (pkg-rollback-package 'magit) verifies (a) the call returns
t, (b) the captured nix argv carries the install subcommand
resolved by `nelix-core--nix-install-subcommand' (= `install' under
the macro's pre-seeded 2.18.0 cache), (c) the rendered flake
references the surviving package only — magit must NOT appear
anywhere in the flake and ripgrep MUST."
  (require 'nelix-dsl)
  (let* ((captured-args nil)
         (captured-flake nil)
         (flake-path "/tmp/nelix-core-test/flake.nix"))
    (unwind-protect
        (let ((nelix-core--registry (make-hash-table :test 'eq)))
          (puthash 'magit
                   '(:name magit
                     :version "3.3.0"
                     :source (:type url-fetch
                              :url "https://example.invalid/magit.tar.gz"
                              :sha256 "sha256-magit")
                     :build-system (:type emacs-package)
                     :inputs nil
                     :native-inputs nil)
                   nelix-core--registry)
          (puthash 'ripgrep
                   '(:name ripgrep
                     :version "13.0.0"
                     :source (:type url-fetch
                              :url "https://example.invalid/ripgrep.tar.gz"
                              :sha256 "sha256-ripgrep")
                     :build-system (:type emacs-package)
                     :inputs nil
                     :native-inputs nil)
                   nelix-core--registry)
          (let ((nelix-core--write-flake-fn
                 (lambda ()
                   ;; Capture the flake string the production code
                   ;; would have written to disk.  Walking the
                   ;; (let-bound) registry mirrors what
                   ;; `nelix-core--write-flake-default' would do.
                   (setq captured-flake (nelix-core--render-flake))
                   flake-path)))
            (nelix-core-test--with-mock
                (lambda (args)
                  (cond
                   ;; Initial active-generation lookup uses the
                   ;; persistent mirror, no shell-out — but post-
                   ;; rollback `pkg-list-generations' refreshes the
                   ;; mirror.
                   ((and (member "profile" args)
                         (member "history" args)
                         (member "--json" args))
                    (list :exit 0
                          :stdout "{\"generations\":[]}"
                          :stderr ""))
                   ;; Hook re-run consults pkg-list — empty profile is
                   ;; benign.
                   ((and (member "profile" args)
                         (member "list" args)
                         (member "--json" args))
                    (list :exit 0
                          :stdout "{\"version\":3,\"elements\":{}}"
                          :stderr ""))
                   ;; The rollback `nix profile install'
                   ;; invocation we want to inspect.
                   ((and (member "profile" args)
                         (or (member "add" args)
                             (member "install" args)))
                    (setq captured-args args)
                    (list :exit 0 :stdout "" :stderr ""))
                   (t (ert-fail (format "unexpected nix args: %S" args)))))
              ;; Pre-seed mirror — current = (magit ripgrep), active.
              (nelix-core--generations-cache-put
               (list (list :id 7
                           :date "2026-05-04T20:00:00Z"
                           :packages '(magit ripgrep)
                           :active t)))
              (should (eq t (pkg-rollback-package 'magit))))))
      (when (file-exists-p "/tmp/nelix-core-test")
        (delete-directory "/tmp/nelix-core-test" t)))
    (should captured-args)
    (should (member "profile" captured-args))
    ;; Macro pre-seeds 2.18.0 → install subcommand on this branch.
    (should (member "install" captured-args))
    (should-not (member "add" captured-args))
    ;; Rendered flake must reference only the surviving package.
    (should captured-flake)
    (should (string-match-p "ripgrep" captured-flake))
    (should-not (string-match-p "magit" captured-flake))
    ;; The flakeref handed to nix should target the surviving package.
    (should (cl-some (lambda (a)
                       (and (stringp a)
                            (string-match-p "#ripgrep\\'" a)))
                     captured-args))
    (should-not (cl-some (lambda (a)
                           (and (stringp a)
                                (string-match-p "#magit\\'" a)))
                         captured-args))))

(ert-deftest nelix-core-test-rollback-package-refuses-no-ir ()
  "pkg-rollback-package signals when a remaining pkg has no IR.

Pre-seeds the mirror with current = (foo ripgrep), registers ONLY
foo (= the package being rolled back) — ripgrep has no IR so the
re-render would silently drop it.  Refuses with the L25 spec
suggestion to use whole-profile `pkg-rollback' instead.

Variant of the spec wording: the package being rolled back has IR
(foo) but a sibling installed via raw nixpkgs lookup (ripgrep) does
not, so the safety check fires before any flake render."
  (require 'nelix-dsl)
  (let ((nelix-core--registry (make-hash-table :test 'eq)))
    (puthash 'foo
             '(:name foo
               :version "1.0"
               :source (:type url-fetch
                        :url "https://example.invalid/foo.tar.gz"
                        :sha256 "sha256-foo")
               :build-system (:type emacs-package)
               :inputs nil
               :native-inputs nil)
             nelix-core--registry)
    (nelix-core-test--with-mock
        (lambda (_args)
          ;; Mirror is pre-populated; no shell-out should fire before
          ;; the IR check refuses.  The rollback path itself must not
          ;; reach `nix profile install'.
          (list :exit 0 :stdout "" :stderr ""))
      (nelix-core--generations-cache-put
       (list (list :id 4
                   :date "2026-05-04T19:00:00Z"
                   :packages '(foo ripgrep)
                   :active t)))
      (let ((err (should-error (pkg-rollback-package 'foo)
                               :type 'nelix-error)))
        (should (string-match-p "pkg-rollback" (cadr err)))
        (should (string-match-p "ripgrep" (cadr err)))))))

(ert-deftest nelix-core-test-rollback-package-not-in-current ()
  "pkg-rollback-package signals when target pkg is absent from active gen.

Pre-seeds the mirror with current = (ripgrep) and asks to roll back
magit, which is not installed.  The call must refuse with
`nelix-error' carrying a `not currently installed' hint without
shelling out to nix."
  (require 'nelix-dsl)
  (nelix-core-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-rollback-package must not shell out when pkg is absent"))
    (nelix-core--generations-cache-put
     (list (list :id 2
                 :date "2026-05-04T18:30:00Z"
                 :packages '(ripgrep)
                 :active t)))
    (let ((err (should-error (pkg-rollback-package 'magit)
                             :type 'nelix-error)))
      (should (string-match-p "not currently installed" (cadr err))))))

;;;; --- Phase 4-F: pkg-install multi-package dispatch -----------------------

(ert-deftest nelix-core-test-multi-install-symbols-single-nix-call ()
  "pkg-install with a list of symbols renders the flake once and
invokes nix once with all flakerefs."
  (require 'nelix-dsl)
  (let* ((install-args nil)
         (render-count 0)
         (flake-path "/tmp/nelix-core-test-multi/flake.nix")
         (nelix-core--registry (make-hash-table :test 'eq)))
    (puthash 'magit
             '(:name magit :version "3.3.0"
               :source (:type url-fetch :url "https://example.invalid/magit.tar.gz"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (puthash 'dash
             '(:name dash :version "2.20.0"
               :source (:type url-fetch :url "https://example.invalid/dash.tar.gz"
                        :sha256 "sha256-dash")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (puthash 'transient
             '(:name transient :version "0.7.0"
               :source (:type url-fetch :url "https://example.invalid/transient.tar.gz"
                        :sha256 "sha256-transient")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (let ((nelix-core--write-flake-fn
           (lambda () (cl-incf render-count) flake-path)))
      (nelix-core-test--with-mock
          (lambda (args)
            ;; Capture only the install invocation; subsequent
            ;; `profile list --json' calls from the after-install hook
            ;; should not clobber it.
            (when (and (null install-args)
                       (or (member "install" args) (member "add" args)))
              (setq install-args args))
            (list :exit 0 :stdout "[]" :stderr ""))
        (should (eq t (pkg-install '(magit dash transient)
                                   :no-auto-deps t)))
        (should (= 1 render-count))
        (should (member "profile" install-args))
        (should (or (member "install" install-args)
                    (member "add" install-args)))
        ;; All three flakerefs in argv, in order.
        (let* ((flake-dir (directory-file-name
                           (file-name-directory flake-path)))
               (expected-flakerefs
                (list (format "path:%s#magit" flake-dir)
                      (format "path:%s#dash" flake-dir)
                      (format "path:%s#transient" flake-dir))))
          (dolist (ref expected-flakerefs)
            (should (member ref install-args))))))))

(ert-deftest nelix-core-test-multi-install-strings-uses-nixpkgs-flakerefs ()
  "pkg-install with a list of strings emits nixpkgs#NAME flakerefs and
skips the flake render entirely (no IR to render)."
  (let* ((captured-args nil)
         (render-fired nil))
    (let ((nelix-core--write-flake-fn
           (lambda () (setq render-fired t) "/tmp/should-not-render/flake.nix")))
      (nelix-core-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-install '("ripgrep" "fd"))))
        (should (null render-fired))
        (should (member "nixpkgs#ripgrep" captured-args))
        (should (member "nixpkgs#fd" captured-args))))))

(ert-deftest nelix-core-test-multi-install-mixed-symbols-strings ()
  "Mixed list installs both registry symbols (path:...#sym) and
nixpkgs strings (nixpkgs#name) in a single nix invocation."
  (require 'nelix-dsl)
  (let* ((install-args nil)
         (flake-path "/tmp/nelix-core-test-mixed/flake.nix")
         (nelix-core--registry (make-hash-table :test 'eq)))
    (puthash 'magit
             '(:name magit :version "3.3.0"
               :source (:type url-fetch :url "https://example.invalid/magit.tar.gz"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (let ((nelix-core--write-flake-fn (lambda () flake-path)))
      (nelix-core-test--with-mock
          (lambda (args)
            (when (and (null install-args)
                       (or (member "install" args) (member "add" args)))
              (setq install-args args))
            (list :exit 0 :stdout "[]" :stderr ""))
        (should (eq t (pkg-install '(magit "ripgrep")
                                   :no-auto-deps t)))
        (let ((flake-dir (directory-file-name
                          (file-name-directory flake-path))))
          (should (member (format "path:%s#magit" flake-dir) install-args)))
        (should (member "nixpkgs#ripgrep" install-args))))))

(ert-deftest nelix-core-test-multi-install-empty-list-errors ()
  "pkg-install with an empty list signals `nelix-error' before nix."
  (nelix-core-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-install must not shell out on empty NAMES"))
    (let ((err (should-error (pkg-install '()) :type 'nelix-error)))
      ;; nil is dispatched as a non-list (not consp), so message complains
      ;; about the type, not emptiness — both are acceptable user-facing
      ;; signals.  Just assert the signal type.
      (should (consp err)))))

(ert-deftest nelix-core-test-multi-install-with-require-errors ()
  ":require is rejected with a list NAME (ambiguous semantics)."
  (nelix-core-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-install must not shell out when :require is rejected"))
    (let ((err (should-error
                (pkg-install '("ripgrep" "fd") :require 'ripgrep)
                :type 'nelix-error)))
      (should (string-match-p ":require" (cadr err))))))

(ert-deftest nelix-core-test-multi-install-undefined-symbol-errors-before-nix ()
  "An undefined symbol in the NAMES list fails registry-get before nix."
  (require 'nelix-dsl)
  (let ((nelix-core--registry (make-hash-table :test 'eq)))
    ;; magit registered, nope is missing.
    (puthash 'magit
             '(:name magit :version "1.0"
               :source (:type url-fetch :url "https://example.invalid/magit.tar.gz"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (nelix-core-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-install must not shell out on undefined symbol"))
      (should-error (pkg-install '(magit nope) :no-auto-deps t)
                    :type 'nelix-undefined-package))))

(ert-deftest nelix-core-test-multi-install-async-happy-runs-on-success ()
  "Async multi-install fires :on-success once with :names NAMES (not :name)."
  (require 'nelix-dsl)
  (let* ((captured nil)
         (make-process-orig (symbol-function 'make-process))
         (nelix-core--registry (make-hash-table :test 'eq)))
    (puthash 'magit
             '(:name magit :version "3.3.0"
               :source (:type url-fetch :url "https://example.invalid/magit.tar.gz"
                        :sha256 "sha256-magit")
               :build-system (:type emacs-package))
             nelix-core--registry)
    (cl-letf (((symbol-function 'nelix-compat-make-process-async)
               (lambda (&rest plist)
                 (let ((replaced (copy-sequence plist)))
                   (setq replaced (plist-put replaced :command (list "true")))
                   (apply make-process-orig replaced))))
              ((symbol-function 'nelix-core--write-flake-fn)
               (lambda () "/tmp/nelix-core-test-multi-async/flake.nix")))
      (let ((nelix-core--write-flake-fn
             (lambda () "/tmp/nelix-core-test-multi-async/flake.nix")))
        (nelix-core-test--with-mock
            (lambda (_args)
              (list :exit 0 :stdout "" :stderr ""))
          (let ((proc (pkg-install '(magit "ripgrep")
                                   :async t
                                   :no-auto-deps t
                                   :on-success
                                   (lambda (result) (setq captured result))
                                   :on-error
                                   (lambda (err)
                                     (ert-fail
                                      (format ":on-error fired: %S" err))))))
            (should (processp proc))
            (nelix-core-test--wait-until (lambda () captured))
            (should (eq :installed (plist-get captured :status)))
            (should (equal '(magit "ripgrep") (plist-get captured :names)))
            ;; Single-name :name key MUST NOT appear in the multi case.
            (should-not (plist-member captured :name))))))))

;;;; --- Phase 4-G: nix CLI credential injection -----------------------------

(defmacro nelix-core-test--with-env (bindings &rest body)
  "Set BINDINGS env vars for BODY; restore on exit."
  (declare (indent 1))
  `(let ((nelix-core-test--saved
          (mapcar (lambda (b) (cons (car b) (getenv (car b))))
                  ',bindings)))
     (unwind-protect
         (progn
           ,@(mapcar (lambda (b) `(setenv ,(car b) ,(cadr b)))
                     bindings)
           ,@body)
       (dolist (s nelix-core-test--saved)
         (setenv (car s) (cdr s))))))

(ert-deftest nelix-core-test-nix-credential-args-with-env ()
  "GITHUB_TOKEN set → --option extra-access-tokens emitted."
  (nelix-core-test--with-env (("GITHUB_TOKEN" "ghp_xyz")
                             ("GH_TOKEN" nil)
                             ("GITLAB_TOKEN" nil)
                             ("CODEBERG_TOKEN" nil))
    (let ((args (nelix-core--nix-credential-args)))
      (should (equal "--option" (car args)))
      (should (equal "extra-access-tokens" (cadr args)))
      (should (string-match-p "github\\.com=ghp_xyz" (caddr args))))))

(ert-deftest nelix-core-test-nix-credential-args-multi-host ()
  "Both GitHub + GitLab tokens → space-separated host=token pairs."
  (nelix-core-test--with-env (("GITHUB_TOKEN" "ghp_a")
                             ("GITLAB_TOKEN" "glpat_b")
                             ("GH_TOKEN" nil)
                             ("CODEBERG_TOKEN" nil))
    (let ((args (nelix-core--nix-credential-args)))
      (should (string-match-p "github\\.com=ghp_a" (caddr args)))
      (should (string-match-p "gitlab\\.com=glpat_b" (caddr args))))))

(ert-deftest nelix-core-test-nix-credential-args-no-env ()
  "All env vars unset → returns nil (no nix CLI flag added)."
  (nelix-core-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil)
                             ("GITLAB_TOKEN" nil) ("CODEBERG_TOKEN" nil))
    (should-not (nelix-core--nix-credential-args))))

(ert-deftest nelix-core-test-call-nix-default-prepends-credential-args ()
  "nelix-core--call-nix-default prepends credential args to ARGS."
  (nelix-core-test--with-env (("GITHUB_TOKEN" "ghp_seen") ("GH_TOKEN" nil)
                             ("GITLAB_TOKEN" nil) ("CODEBERG_TOKEN" nil))
    (let ((seen-args nil))
      (cl-letf (((symbol-function 'nelix-compat-call-process)
                 (lambda (_program args)
                   (setq seen-args args)
                   (list :exit 0 :stdout "" :stderr ""))))
        (nelix-core--call-nix-default '("--version"))
        (should (equal "--option" (nth 0 seen-args)))
        (should (equal "extra-access-tokens" (nth 1 seen-args)))
        (should (string-match-p "github\\.com=ghp_seen" (nth 2 seen-args)))
        (should (equal "--version" (nth 3 seen-args)))))))

(provide 'nelix-core-test)
;;; nelix-core-test.el ends here
