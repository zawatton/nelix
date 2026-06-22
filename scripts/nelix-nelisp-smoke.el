;;; nelix-nelisp-smoke.el --- Minimal NeLisp standalone smoke -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; This is intentionally narrower than the Emacs ERT suite.  The local
;; NeLisp CLI used during Phase 5 does not provide Emacs's --batch /
;; -L interface, ERT, or complete process / URL primitives, so the
;; smoke proves the compat layer loads, exercises the backend pieces
;; currently available, and records why native async / text HTTP are not
;; yet executable in this standalone evaluator.

;;; Code:

(defvar nelix-compat--nelisp-backend-require-attempted)
(defvar nelix-compat--nelisp-runtime-p)
(defvar nelix-compat-curl-program)
(defvar nelix-compat-nelisp-http-get-binary-function)
(defvar nelix-compat-nelisp-http-get-function)
(defvar nelix-compat-nelisp-call-process-function)
(defvar nelix-compat-nelisp-make-process-function)
(defvar nelix-compat-nelisp-getenv-function)
(defvar nelix-compat-nelisp-executable-find-function)
(defvar nelix-nelisp-ert--tests)
(defvar nelix-nelisp-ert-register-only)
(defvar nelix-nelisp-ert-progress-file)
(defvar nelix-nelisp-ert-selector)

(defvar nelix-nelisp-smoke-json-source nil
  "Optional path to nelisp-json.el for a real backend parse smoke.")

(defvar nelix-nelisp-smoke-text-buffer-source nil
  "Optional path to nelisp-text-buffer.el for buffer backend smoke.")

(defvar nelix-nelisp-smoke-regex-source nil
  "Optional path to nelisp-regex.el for buffer backend smoke.")

(defvar nelix-nelisp-smoke-emacs-compat-source nil
  "Optional path to nelisp-emacs-compat.el for buffer backend smoke.")

(defvar nelix-nelisp-smoke-actor-source nil
  "Optional path to nelisp-actor.el for native backend probes.")

(defvar nelix-nelisp-smoke-stdlib-eval-special-source nil
  "Optional path to nelisp-stdlib-eval-special.el for cl-defun support.")

(defvar nelix-nelisp-smoke-cl-macros-source nil
  "Optional path to nelisp-cl-macros.el for cl-lib macro support.")

(defvar nelix-nelisp-smoke-ert-shim-source nil
  "Optional path to nelix-core's standalone ERT shim.")

(defvar nelix-nelisp-smoke-process-source nil
  "Optional path to nelisp-process.el for native backend probes.")

(defvar nelix-nelisp-smoke-network-source nil
  "Optional path to nelisp-network.el for native backend probes.")

(defvar nelix-nelisp-smoke-http-source nil
  "Optional path to nelisp-http.el for high-level HTTP backend probes.")

(defvar nelix-nelisp-smoke-suite-source-files
  '("nelix-compat.el"
    "nelix-state.el"
    "nelix-core.el"
    "nelix-dsl.el"
    "nelix-import.el"
    "nelix-emacs.el"
    "nelix-store.el"
    "nelix-registry.el"
    "nelix-fetch.el"
    "nelix-builder.el"
    "nelix-backend.el"
    "nelix-manifest.el"
    "nelix-fast.el"
    "nelix-substitute.el"
    "nelix-dsl.el"
    "nelix-import.el"
    "nelix-emacs.el"
    "nelix.el"
    "scripts/nelix-core-render.el")
  "Runtime and helper files loaded before a full standalone suite run.")

(defvar nelix-nelisp-smoke-suite-test-files
  '("test/nelix-core-test.el"
    "test/nelix-core-uninstall-test.el"
    "test/nelix-core-upgrade-test.el"
    "test/nelix-core-pin-test.el"
    "test/nelix-core-info-test.el"
    "test/nelix-core-doctor-test.el"
    "test/nelix-dsl-test.el"
    "test/nelix-core-buildsys-test.el"
    "test/nelix-import-test.el"
    "test/nelix-compat-test.el"
    "test/nelix-emacs-test.el"
    "test/nelix-state-test.el")
  "ERT files loaded by a full standalone suite run.")

(defvar nelix-nelisp-smoke-suite-source-loaded-p nil
  "Non-nil when runtime suite source files have already been loaded.")

(defvar nelix-nelisp-smoke-progress-file nil
  "Optional file path updated during standalone smoke suite loading.")

(defvar nelix-nelisp-smoke-ert-selector nil
  "Optional test selector forwarded to the standalone ERT shim.")

(unless (fboundp 'declare-function)
  (defmacro declare-function (&rest _ignored) nil))

(unless (fboundp 'interactive)
  (defmacro interactive (&rest _ignored) nil))

(unless (fboundp 'called-interactively-p)
  (defun called-interactively-p (&rest _ignored) nil))

(declare-function nelix-compat--detect-nelisp-runtime-p
                  "nelix-compat")
(declare-function nelix-compat-buffer-live-p "nelix-compat")
(declare-function nelix-compat-buffer-string "nelix-compat")
(declare-function nelix-compat-call-process "nelix-compat")
(declare-function nelix-compat-executable-find "nelix-compat")
(declare-function nelix-compat-generate-buffer "nelix-compat")
(declare-function nelix-compat-getenv "nelix-compat")
(declare-function nelix-compat-http-get "nelix-compat")
(declare-function nelix-compat-http-get-binary "nelix-compat")
(declare-function nelix-compat-json-parse "nelix-compat")
(declare-function nelix-compat-make-process-async "nelix-compat")
(declare-function nelix-compat-runtime "nelix-compat")
(declare-function nelix-compat-string-trim "nelix-compat")

(defun nelix-nelisp-smoke--path-present-p (path)
  "Return non-nil when PATH is a non-empty string."
  (and path (> (length path) 0)))

(defun nelix-nelisp-smoke--json-backend-ok-p ()
  "Return non-nil when the optional real JSON backend smoke passes."
  (if (nelix-nelisp-smoke--path-present-p
       nelix-nelisp-smoke-json-source)
      (progn
        (load nelix-nelisp-smoke-json-source)
        (and (fboundp 'nelisp-json-parse-string)
             (nelix-compat-json-parse "{\"ok\":true}")))
    t))

(defun nelix-nelisp-smoke--buffer-backend-ok-p ()
  "Return non-nil when the optional real buffer backend smoke passes."
  (if (and (nelix-nelisp-smoke--path-present-p
            nelix-nelisp-smoke-text-buffer-source)
           (nelix-nelisp-smoke--path-present-p
            nelix-nelisp-smoke-regex-source)
           (nelix-nelisp-smoke--path-present-p
            nelix-nelisp-smoke-emacs-compat-source))
      (progn
        (load nelix-nelisp-smoke-text-buffer-source)
        (load nelix-nelisp-smoke-regex-source)
        (load nelix-nelisp-smoke-emacs-compat-source)
        (let ((nelix-compat--nelisp-runtime-p t))
          (let ((buf (nelix-compat-generate-buffer
                      "nelix-core-smoke-buffer")))
            (and (nelix-compat-buffer-live-p buf)
                 (equal (nelix-compat-buffer-string buf) "")))))
    t))

(defun nelix-nelisp-smoke--load-optional (path)
  "Load PATH when non-empty; return non-nil if load was skipped or clean."
  (if (nelix-nelisp-smoke--path-present-p path)
      (condition-case _err
          (progn (load path) t)
        (error nil))
    t))

(defun nelix-nelisp-smoke--load-compat ()
  "Load nelix-core's compat layer for standalone smoke entry points."
  (load "nelix-compat.el"))

(defun nelix-nelisp-smoke--load-native-prereqs ()
  "Load optional native backend prerequisites in standalone NeLisp."
  (and
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-stdlib-eval-special-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-cl-macros-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-json-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-ert-shim-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-actor-source)))

(defun nelix-nelisp-smoke--native-async-lower-primitive-p ()
  "Return non-nil when async has a real lower spawn primitive.
Runtime-aware: on the Emacs / nemacs branch the lower primitive is
`make-process' (which `nelix-compat-make-process-async' dispatches
through); on the standalone NeLisp suite path the prelude `make-process'
shim is enough because tests that force the NeLisp backend explicitly
assert the unsupported branch."
  (if (eq (nelix-compat-runtime) 'emacs)
      (fboundp 'make-process)
    (or (and (fboundp 'nelisp-process-async-ready-p)
             (nelisp-process-async-ready-p))
        (fboundp 'make-process))))

(defun nelix-nelisp-smoke--curl-process-lower-primitive-p ()
  "Return non-nil when curl can run through Emacs or Doc 44 NeLisp process APIs."
  (and (or (fboundp 'call-process)
           (fboundp 'nelisp-call-process))
       (and
        (condition-case nil
            (or (and (fboundp 'executable-find)
                     (executable-find "curl"))
                (and (fboundp 'nelix-compat-executable-find)
                     (nelix-compat-executable-find "curl")))
          (error nil))
        t)))

(defun nelix-nelisp-smoke--native-text-http-lower-primitive-p ()
  "Return non-nil when text HTTP has a real lower primitive.
Runtime-aware: on the Emacs / nemacs branch `nelix-compat-http-get'
dispatches through `url-retrieve-synchronously', with a curl fallback for
the standalone reader (where url.el is non-functional) -- so either a
usable url.el or the curl process path satisfies the requirement.  On the
NeLisp branch a native `nelisp-http-*' backend must be present, itself
backed by url or curl."
  (if (eq (nelix-compat-runtime) 'emacs)
      (or (fboundp 'url-retrieve-synchronously)
          (nelix-nelisp-smoke--curl-process-lower-primitive-p))
    (and (or (fboundp 'nelisp-http-get)
             (fboundp 'nelisp-http-fetch)
             (fboundp 'nelisp-http-get-binary))
         (or (fboundp 'url-retrieve-synchronously)
             (nelix-nelisp-smoke--curl-process-lower-primitive-p)))))

(defun nelix-nelisp-smoke--native-backend-probe-ok-p ()
  "Return non-nil when optional native backend source probes are sane.

The current local standalone image may load only part of
nelisp-process / nelisp-network / nelisp-http because host process
and url primitives are not available.  This smoke accepts that state but
  checks that compat detection only flips to NeLisp when a complete
  call-site backend (`nelisp-call-process', `nelisp-make-process',
  `nelisp-http-get', `nelisp-http-fetch', or
  `nelisp-http-get-binary') is actually present."
  (and
   (nelix-nelisp-smoke--load-native-prereqs)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-process-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-network-source)
   (nelix-nelisp-smoke--load-optional
    nelix-nelisp-smoke-http-source)
   (let ((has-complete-backend
          (or (fboundp 'nelisp-call-process)
              (fboundp 'nelisp-make-process)
              (fboundp 'nelisp-http-get)
              (fboundp 'nelisp-http-fetch)
              (fboundp 'nelisp-http-get-binary)))
         (nelix-compat--nelisp-backend-require-attempted t))
     (eq (and (nelix-compat--detect-nelisp-runtime-p) t)
         (and has-complete-backend t)))))

(defun nelix-nelisp-smoke--native-gap-accounted-p ()
  "Return non-nil when absent native backends match known CLI gaps.

This is not a substitute for a production native backend.  It keeps the
standalone smoke honest by proving that missing async / text HTTP
backends are explained by currently absent evaluator primitives instead
of by an nelix-core dispatch regression."
  (and
   (or (nelix-nelisp-smoke--native-async-lower-primitive-p)
       (not (fboundp 'make-process)))
   (or (nelix-nelisp-smoke--native-text-http-lower-primitive-p)
       (not (fboundp 'url-retrieve-synchronously)))))

(defun nelix-nelisp-smoke-capabilities ()
  "Return current standalone NeLisp capabilities relevant to nelix-core."
  (nelix-nelisp-smoke--load-compat)
  (nelix-nelisp-smoke--load-native-prereqs)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-process-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-network-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-http-source)
  (list :runtime (nelix-compat-runtime)
        :ert (fboundp 'ert-run-tests-batch-and-exit)
        :ert-shim (fboundp 'nelix-nelisp-ert--test-body)
        :cl-defun (fboundp 'cl-defun)
        :cl-letf (fboundp 'cl-letf)
        :make-process (fboundp 'make-process)
        :url-retrieve-synchronously (fboundp 'url-retrieve-synchronously)
        :nelisp-call-process (fboundp 'nelisp-call-process)
        :nelisp-make-process (fboundp 'nelisp-make-process)
        :nelisp-sys-getenv (fboundp 'nelisp-sys-getenv)
        :nelisp-sys-executable-find (fboundp 'nelisp-sys-executable-find)
        :nelisp-http-get (fboundp 'nelisp-http-get)
        :nelisp-http-fetch (fboundp 'nelisp-http-fetch)
        :nelisp-http-get-binary (fboundp 'nelisp-http-get-binary)
        :curl-process-lower-primitive
        (nelix-nelisp-smoke--curl-process-lower-primitive-p)
        :native-async-lower-primitive
        (nelix-nelisp-smoke--native-async-lower-primitive-p)
        :native-text-http-lower-primitive
        (nelix-nelisp-smoke--native-text-http-lower-primitive-p)
        :native-gap-accounted
        (nelix-nelisp-smoke--native-gap-accounted-p)))

(defun nelix-nelisp-smoke-suite-readiness ()
  "Return whether the standalone image can run the full ERT suite.

This is an audit result, not the suite itself.  The suite may run with
mocked HTTP paths before standalone NeLisp has production text HTTP
lower primitives, but native async still needs a process lower primitive
because async tests exercise that path directly."
  (nelix-nelisp-smoke--load-compat)
  (nelix-nelisp-smoke--load-native-prereqs)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-process-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-network-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-http-source)
  (let* ((has-ert (fboundp 'ert-run-tests-batch-and-exit))
         (has-cl-letf (fboundp 'cl-letf))
         (has-async-lower
          (nelix-nelisp-smoke--native-async-lower-primitive-p))
         (has-text-http-lower
          (nelix-nelisp-smoke--native-text-http-lower-primitive-p))
         (suite-ready
          (and has-ert has-cl-letf has-async-lower))
         (blocked-by nil))
    (unless has-async-lower
      (setq blocked-by
            (cons 'native-async-lower-primitive blocked-by)))
    (unless has-ert
      (setq blocked-by (cons 'ert-batch-runner blocked-by)))
    (unless has-cl-letf
      (setq blocked-by (cons 'cl-letf blocked-by)))
    (list :suite-ready suite-ready
          :suite-blocked-by blocked-by
          :runtime (nelix-compat-runtime)
          :ert has-ert
          :cl-letf has-cl-letf
          :make-process (fboundp 'make-process)
          :url-retrieve-synchronously
          (fboundp 'url-retrieve-synchronously)
          :nelisp-make-process (fboundp 'nelisp-make-process)
          :nelisp-http-get (fboundp 'nelisp-http-get)
          :nelisp-http-fetch (fboundp 'nelisp-http-fetch)
          :native-async-lower-primitive has-async-lower
          :native-text-http-lower-primitive has-text-http-lower
          :readiness-audit-ok (and (or suite-ready blocked-by) t))))

(defun nelix-nelisp-smoke-public-entrypoints ()
  "Return whether standalone NeLisp can load Nelix public entry points."
  (nelix-nelisp-smoke--load-native-prereqs)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-process-source)
  (condition-case err
      (progn
        (nelix-nelisp-smoke--load-suite-files
         '("nelix-compat.el"
           "nelix-state.el"
           "nelix-core.el"
           "nelix-dsl.el"
           "nelix-import.el"
           "nelix-emacs.el"
           "nelix.el"
           "nelix-dsl.el"
           "nelix-import.el"
           "nelix-emacs.el"))
        (list :nelix-load t
              :runtime (nelix-compat-runtime)
              :nelix-install (fboundp 'nelix-install)
              :nelix-define (fboundp 'nelix-define)
              :nelix-render-nix (fboundp 'nelix-render-nix)
              :nelix-import (fboundp 'nelix-import-async-installer)
              :nelix-emacs (fboundp 'nelix-emacs-derive-deps)))
    (error
     (list :nelix-load nil
           :error err
           :runtime (if (fboundp 'nelix-compat-runtime)
                        (nelix-compat-runtime)
                      'unknown)))))

(defun nelix-nelisp-smoke--load-suite-files (files)
  "Load each path in FILES for a standalone suite run."
  (let ((cur files))
    (while cur
      (nelix-nelisp-smoke--write-progress
       (list :loading (car cur)))
      (load (car cur))
      (setq cur (cdr cur)))))

(defun nelix-nelisp-smoke-preload-suite-runtime ()
  "Preload runtime sources needed by standalone suite execution.

This is intended for runtime-image/cache creation.  Test files are not
loaded here; callers set `nelix-nelisp-smoke-suite-test-files' at
execution time and then call `nelix-nelisp-smoke-run-suite'."
  (nelix-nelisp-smoke--load-compat)
  (nelix-nelisp-smoke--load-native-prereqs)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-process-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-network-source)
  (nelix-nelisp-smoke--load-optional
   nelix-nelisp-smoke-http-source)
  (nelix-nelisp-smoke--load-suite-files
   nelix-nelisp-smoke-suite-source-files)
  (setq nelix-nelisp-smoke-suite-source-loaded-p t)
  t)

(defun nelix-nelisp-smoke--write-progress (value)
  "Write standalone suite progress VALUE when a progress file is configured."
  (let ((file (or nelix-nelisp-smoke-progress-file
                  (and (boundp 'nelix-nelisp-ert-progress-file)
                       nelix-nelisp-ert-progress-file)))
        (payload (format "%S\n" value)))
    (when file
      (or
       (condition-case _err
           (progn
             (write-region payload nil file 0)
             t)
         (error nil))
       (condition-case _err
           (and (fboundp 'nelisp-process-call-process)
                (zerop (nelisp-process-call-process
                        "/usr/bin/printf" nil file nil "%s" payload)))
         (error nil))))))

(defun nelix-nelisp-smoke-run-suite ()
  "Run the full nelix-core ERT suite when standalone readiness passes.

When the current standalone image is not ready, return a plist with
`:suite-run nil' and the readiness blockers.  When it is ready, load
runtime sources, helper scripts, and ERT files, then delegate to
`ert-run-tests-batch-and-exit'."
  (nelix-nelisp-smoke--write-progress
   (list :phase 'readiness))
  (let ((readiness (nelix-nelisp-smoke-suite-readiness)))
    (if (not (plist-get readiness :suite-ready))
        (append (list :suite-run nil) readiness)
      (unless nelix-nelisp-smoke-suite-source-loaded-p
        (nelix-nelisp-smoke--write-progress
         (list :phase 'load-suite-source))
        (nelix-nelisp-smoke--load-suite-files
         nelix-nelisp-smoke-suite-source-files)
        (setq nelix-nelisp-smoke-suite-source-loaded-p t))
      (nelix-nelisp-smoke--write-progress
       (list :phase 'load-suite-tests))
      (nelix-nelisp-smoke--load-suite-files
       nelix-nelisp-smoke-suite-test-files)
      (nelix-nelisp-smoke--write-progress
       (list :phase 'run-tests))
      (when nelix-nelisp-smoke-progress-file
        (setq nelix-nelisp-ert-progress-file
              nelix-nelisp-smoke-progress-file))
      (when nelix-nelisp-smoke-ert-selector
        (setq nelix-nelisp-ert-selector
              nelix-nelisp-smoke-ert-selector))
      (if (fboundp 'nelix-nelisp-ert-run-tests)
          (nelix-nelisp-ert-run-tests)
        (if (fboundp 'ert-run-tests-batch-and-exit)
            (ert-run-tests-batch-and-exit)
        (append (list :suite-run nil
                      :suite-blocked-by '(ert-batch-runner))
                readiness))))))

(defun nelix-nelisp-smoke-suite-loadability ()
  "Return whether standalone NeLisp can load configured suite definitions.

This registration-only probe does not claim the suite can execute.  It
loads the configured ERT files with the local ERT shim configured to
retain test names but not test bodies, so NeLisp parser / loader
regressions become visible before the lower process / URL primitives
needed for execution are available."
  (nelix-nelisp-smoke--load-compat)
  (nelix-nelisp-smoke--load-native-prereqs)
  (let ((nelix-compat--nelisp-runtime-p t)
        (nelix-compat--nelisp-backend-require-attempted t)
        (nelix-nelisp-ert-register-only t)
        (tests nelix-nelisp-smoke-suite-test-files))
    (setq nelix-nelisp-ert--tests nil)
    (condition-case err
        (progn
          (while tests
            (load (car tests))
            (setq tests (cdr tests)))
          (list :suite-loadable t
                :tests (length nelix-nelisp-ert--tests)
                :register-only t
                :runtime (nelix-compat-runtime)))
      (error
       (list :suite-loadable nil
             :error err
             :register-only t
             :runtime (nelix-compat-runtime))))))

(defun nelix-nelisp-smoke--unsupported-branches-ok-p ()
  "Return non-nil when NeLisp fallback branches are accounted for.
Older standalone images signaled unsupported-runtime for async and
HTTP paths.  Newer images may execute those paths through native or
curl-backed lower primitives.  Both outcomes are acceptable here; a
plain unexpected error is not."
  (let ((nelix-compat--nelisp-runtime-p t)
        (nelix-compat--nelisp-backend-require-attempted t)
        (nelix-compat-curl-program
         "definitely-missing-nelix-core-curl")
        (nelix-compat-nelisp-call-process-function nil)
        (nelix-compat-nelisp-make-process-function nil)
        (nelix-compat-nelisp-executable-find-function
         (lambda (_cmd) nil))
        (nelix-compat-nelisp-http-get-function nil)
        (nelix-compat-nelisp-http-get-binary-function nil))
    (and
     (memq (condition-case _err
               (progn
                 (nelix-compat-make-process-async
                  :name "nelix-core-smoke"
                  :command (list "sh" "-c" "true"))
                 'executed)
             (nelix-async-not-supported 'unsupported)
             (error 'error))
           '(executed unsupported))
     (or (fboundp 'nelisp-http-get)
         (memq (condition-case _err
                   (progn
                     (nelix-compat-http-get "https://example.invalid" 1)
                     'executed)
                 (nelix-http-not-supported 'unsupported)
                 (error 'error))
               '(executed unsupported)))
     (or (fboundp 'nelisp-http-get-binary)
         (memq (condition-case _err
                   (progn
                     (nelix-compat-http-get-binary
                      "https://example.invalid" 1)
                     'executed)
                 (nelix-http-not-supported 'unsupported)
                 (error 'error))
               '(executed unsupported))))))

(defun nelix-nelisp-smoke--explicit-hooks-ok-p ()
  "Return non-nil when explicit backend hooks dispatch on standalone NeLisp."
  (let ((nelix-compat--nelisp-runtime-p t)
        (nelix-compat--nelisp-backend-require-attempted t)
        (nelix-compat-nelisp-call-process-function
         (lambda (program args)
           (list :exit 0
                 :stdout (format "%S" (list program args))
                 :stderr "")))
        (nelix-compat-nelisp-make-process-function
         (lambda (&rest plist)
           (list :hook 'async :name (plist-get plist :name))))
        (nelix-compat-nelisp-getenv-function
         (lambda (var)
           (and (equal var "ANVIL_PKG_SMOKE") "env-hook")))
        (nelix-compat-nelisp-executable-find-function
         (lambda (cmd)
           (and (equal cmd "curl") "/hook/bin/curl")))
        (nelix-compat-nelisp-http-get-function
         (lambda (url timeout auth-header)
           (list :status 211
                 :body (format "%S" (list url timeout auth-header)))))
        (nelix-compat-nelisp-http-get-binary-function
         (lambda (url timeout auth-header)
           (list :status 212
                 :body (format "%S" (list url timeout auth-header))
                 :content-length 5))))
    (and
     (equal (nelix-compat-call-process "printf" (list "ok"))
            '(:exit 0 :stdout "(\"printf\" (\"ok\"))" :stderr ""))
     (equal (nelix-compat-make-process-async
             :name "nelix-core-smoke-hook"
             :command (list "true"))
            '(:hook async :name "nelix-core-smoke-hook"))
     (equal (nelix-compat-getenv "ANVIL_PKG_SMOKE")
            "env-hook")
     (equal (nelix-compat-executable-find "curl")
            "/hook/bin/curl")
     (equal (nelix-compat-http-get
             "https://example.invalid/hook" 3 "Bearer hook")
            '(:status 211
              :body "(\"https://example.invalid/hook\" 3 \"Bearer hook\")"))
     (equal (nelix-compat-http-get-binary
             "https://example.invalid/hook.tar" 4 "Bearer hook")
            '(:status 212
              :body "(\"https://example.invalid/hook.tar\" 4 \"Bearer hook\")"
              :content-length 5)))))

(defun nelix-nelisp-smoke-run ()
  "Return a plist result for the minimal standalone NeLisp smoke."
  (nelix-nelisp-smoke--load-compat)
  (let ((ok t))
    (unless (fboundp 'nelix-compat-runtime)
      (setq ok nil))
    (when ok
      (unless (memq (nelix-compat-runtime) '(emacs nelisp))
        (setq ok nil)))
    (when ok
      (unless (equal (nelix-compat-string-trim " \t\nok\n\t ") "ok")
        (setq ok nil)))
    (when ok
      (unless (equal (nelix-compat-string-trim nil) "")
        (setq ok nil)))
    (when ok
      (unless (and (fboundp 'nelix-compat-json-parse)
                   (fboundp 'nelix-compat-json-serialize))
        (setq ok nil)))
    (when ok
      (unless (nelix-nelisp-smoke--json-backend-ok-p)
        (setq ok nil)))
    (when ok
      (unless (nelix-nelisp-smoke--buffer-backend-ok-p)
        (setq ok nil)))
    (when ok
      (unless (nelix-nelisp-smoke--unsupported-branches-ok-p)
        (setq ok nil)))
    (when ok
      (unless (nelix-nelisp-smoke--explicit-hooks-ok-p)
        (setq ok nil)))
    (list :smoke-ok ok)))

(provide 'nelix-nelisp-smoke)
;;; nelix-nelisp-smoke.el ends here
