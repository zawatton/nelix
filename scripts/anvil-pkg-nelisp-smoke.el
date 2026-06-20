;;; anvil-pkg-nelisp-smoke.el --- Minimal NeLisp standalone smoke -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; This is intentionally narrower than the Emacs ERT suite.  The local
;; NeLisp CLI used during Phase 5 does not provide Emacs's --batch /
;; -L interface, ERT, or complete process / URL primitives, so the
;; smoke proves the compat layer loads, exercises the backend pieces
;; currently available, and records why native async / text HTTP are not
;; yet executable in this standalone evaluator.

;;; Code:

(defvar anvil-pkg-compat--nelisp-backend-require-attempted)
(defvar anvil-pkg-compat--nelisp-runtime-p)
(defvar anvil-pkg-compat-curl-program)
(defvar anvil-pkg-compat-nelisp-http-get-binary-function)
(defvar anvil-pkg-compat-nelisp-http-get-function)
(defvar anvil-pkg-compat-nelisp-call-process-function)
(defvar anvil-pkg-compat-nelisp-make-process-function)
(defvar anvil-pkg-compat-nelisp-getenv-function)
(defvar anvil-pkg-compat-nelisp-executable-find-function)
(defvar anvil-pkg-nelisp-ert--tests)
(defvar anvil-pkg-nelisp-ert-register-only)
(defvar anvil-pkg-nelisp-ert-progress-file)
(defvar anvil-pkg-nelisp-ert-selector)

(defvar anvil-pkg-nelisp-smoke-json-source nil
  "Optional path to nelisp-json.el for a real backend parse smoke.")

(defvar anvil-pkg-nelisp-smoke-text-buffer-source nil
  "Optional path to nelisp-text-buffer.el for buffer backend smoke.")

(defvar anvil-pkg-nelisp-smoke-regex-source nil
  "Optional path to nelisp-regex.el for buffer backend smoke.")

(defvar anvil-pkg-nelisp-smoke-emacs-compat-source nil
  "Optional path to nelisp-emacs-compat.el for buffer backend smoke.")

(defvar anvil-pkg-nelisp-smoke-actor-source nil
  "Optional path to nelisp-actor.el for native backend probes.")

(defvar anvil-pkg-nelisp-smoke-stdlib-eval-special-source nil
  "Optional path to nelisp-stdlib-eval-special.el for cl-defun support.")

(defvar anvil-pkg-nelisp-smoke-cl-macros-source nil
  "Optional path to nelisp-cl-macros.el for cl-lib macro support.")

(defvar anvil-pkg-nelisp-smoke-ert-shim-source nil
  "Optional path to anvil-pkg's standalone ERT shim.")

(defvar anvil-pkg-nelisp-smoke-process-source nil
  "Optional path to nelisp-process.el for native backend probes.")

(defvar anvil-pkg-nelisp-smoke-network-source nil
  "Optional path to nelisp-network.el for native backend probes.")

(defvar anvil-pkg-nelisp-smoke-http-source nil
  "Optional path to nelisp-http.el for high-level HTTP backend probes.")

(defvar anvil-pkg-nelisp-smoke-suite-source-files
  '("anvil-pkg-compat.el"
    "anvil-pkg-state.el"
    "anvil-pkg.el"
    "anvil-pkg-dsl.el"
    "anvil-pkg-import.el"
    "anvil-pkg-emacs.el"
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
    "scripts/anvil-pkg-render.el")
  "Runtime and helper files loaded before a full standalone suite run.")

(defvar anvil-pkg-nelisp-smoke-suite-test-files
  '("test/anvil-pkg-test.el"
    "test/anvil-pkg-uninstall-test.el"
    "test/anvil-pkg-upgrade-test.el"
    "test/anvil-pkg-pin-test.el"
    "test/anvil-pkg-info-test.el"
    "test/anvil-pkg-doctor-test.el"
    "test/anvil-pkg-dsl-test.el"
    "test/anvil-pkg-buildsys-test.el"
    "test/anvil-pkg-import-test.el"
    "test/anvil-pkg-compat-test.el"
    "test/anvil-pkg-emacs-test.el"
    "test/anvil-pkg-state-test.el")
  "ERT files loaded by a full standalone suite run.")

(defvar anvil-pkg-nelisp-smoke-suite-source-loaded-p nil
  "Non-nil when runtime suite source files have already been loaded.")

(defvar anvil-pkg-nelisp-smoke-progress-file nil
  "Optional file path updated during standalone smoke suite loading.")

(defvar anvil-pkg-nelisp-smoke-ert-selector nil
  "Optional test selector forwarded to the standalone ERT shim.")

(unless (fboundp 'declare-function)
  (defmacro declare-function (&rest _ignored) nil))

(unless (fboundp 'interactive)
  (defmacro interactive (&rest _ignored) nil))

(unless (fboundp 'called-interactively-p)
  (defun called-interactively-p (&rest _ignored) nil))

(declare-function anvil-pkg-compat--detect-nelisp-runtime-p
                  "anvil-pkg-compat")
(declare-function anvil-pkg-compat-buffer-live-p "anvil-pkg-compat")
(declare-function anvil-pkg-compat-buffer-string "anvil-pkg-compat")
(declare-function anvil-pkg-compat-call-process "anvil-pkg-compat")
(declare-function anvil-pkg-compat-executable-find "anvil-pkg-compat")
(declare-function anvil-pkg-compat-generate-buffer "anvil-pkg-compat")
(declare-function anvil-pkg-compat-getenv "anvil-pkg-compat")
(declare-function anvil-pkg-compat-http-get "anvil-pkg-compat")
(declare-function anvil-pkg-compat-http-get-binary "anvil-pkg-compat")
(declare-function anvil-pkg-compat-json-parse "anvil-pkg-compat")
(declare-function anvil-pkg-compat-make-process-async "anvil-pkg-compat")
(declare-function anvil-pkg-compat-runtime "anvil-pkg-compat")
(declare-function anvil-pkg-compat-string-trim "anvil-pkg-compat")

(defun anvil-pkg-nelisp-smoke--path-present-p (path)
  "Return non-nil when PATH is a non-empty string."
  (and path (> (length path) 0)))

(defun anvil-pkg-nelisp-smoke--json-backend-ok-p ()
  "Return non-nil when the optional real JSON backend smoke passes."
  (if (anvil-pkg-nelisp-smoke--path-present-p
       anvil-pkg-nelisp-smoke-json-source)
      (progn
        (load anvil-pkg-nelisp-smoke-json-source)
        (and (fboundp 'nelisp-json-parse-string)
             (anvil-pkg-compat-json-parse "{\"ok\":true}")))
    t))

(defun anvil-pkg-nelisp-smoke--buffer-backend-ok-p ()
  "Return non-nil when the optional real buffer backend smoke passes."
  (if (and (anvil-pkg-nelisp-smoke--path-present-p
            anvil-pkg-nelisp-smoke-text-buffer-source)
           (anvil-pkg-nelisp-smoke--path-present-p
            anvil-pkg-nelisp-smoke-regex-source)
           (anvil-pkg-nelisp-smoke--path-present-p
            anvil-pkg-nelisp-smoke-emacs-compat-source))
      (progn
        (load anvil-pkg-nelisp-smoke-text-buffer-source)
        (load anvil-pkg-nelisp-smoke-regex-source)
        (load anvil-pkg-nelisp-smoke-emacs-compat-source)
        (let ((anvil-pkg-compat--nelisp-runtime-p t))
          (let ((buf (anvil-pkg-compat-generate-buffer
                      "anvil-pkg-smoke-buffer")))
            (and (anvil-pkg-compat-buffer-live-p buf)
                 (equal (anvil-pkg-compat-buffer-string buf) "")))))
    t))

(defun anvil-pkg-nelisp-smoke--load-optional (path)
  "Load PATH when non-empty; return non-nil if load was skipped or clean."
  (if (anvil-pkg-nelisp-smoke--path-present-p path)
      (condition-case _err
          (progn (load path) t)
        (error nil))
    t))

(defun anvil-pkg-nelisp-smoke--load-compat ()
  "Load anvil-pkg's compat layer for standalone smoke entry points."
  (load "anvil-pkg-compat.el"))

(defun anvil-pkg-nelisp-smoke--load-native-prereqs ()
  "Load optional native backend prerequisites in standalone NeLisp."
  (and
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-stdlib-eval-special-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-cl-macros-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-json-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-ert-shim-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-actor-source)))

(defun anvil-pkg-nelisp-smoke--native-async-lower-primitive-p ()
  "Return non-nil when async has a real lower spawn primitive.
Runtime-aware: on the Emacs / nemacs branch the lower primitive is
`make-process' (which `anvil-pkg-compat-make-process-async' dispatches
through); on the standalone NeLisp suite path the prelude `make-process'
shim is enough because tests that force the NeLisp backend explicitly
assert the unsupported branch."
  (if (eq (anvil-pkg-compat-runtime) 'emacs)
      (fboundp 'make-process)
    (or (and (fboundp 'nelisp-process-async-ready-p)
             (nelisp-process-async-ready-p))
        (fboundp 'make-process))))

(defun anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p ()
  "Return non-nil when curl can run through Emacs or Doc 44 NeLisp process APIs."
  (and (or (fboundp 'call-process)
           (fboundp 'nelisp-call-process))
       (and
        (condition-case nil
            (or (and (fboundp 'executable-find)
                     (executable-find "curl"))
                (and (fboundp 'anvil-pkg-compat-executable-find)
                     (anvil-pkg-compat-executable-find "curl")))
          (error nil))
        t)))

(defun anvil-pkg-nelisp-smoke--native-text-http-lower-primitive-p ()
  "Return non-nil when text HTTP has a real lower primitive.
Runtime-aware: on the Emacs / nemacs branch `anvil-pkg-compat-http-get'
dispatches through `url-retrieve-synchronously', with a curl fallback for
the standalone reader (where url.el is non-functional) -- so either a
usable url.el or the curl process path satisfies the requirement.  On the
NeLisp branch a native `nelisp-http-*' backend must be present, itself
backed by url or curl."
  (if (eq (anvil-pkg-compat-runtime) 'emacs)
      (or (fboundp 'url-retrieve-synchronously)
          (anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p))
    (and (or (fboundp 'nelisp-http-get)
             (fboundp 'nelisp-http-fetch)
             (fboundp 'nelisp-http-get-binary))
         (or (fboundp 'url-retrieve-synchronously)
             (anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p)))))

(defun anvil-pkg-nelisp-smoke--native-backend-probe-ok-p ()
  "Return non-nil when optional native backend source probes are sane.

The current local standalone image may load only part of
nelisp-process / nelisp-network / nelisp-http because host process
and url primitives are not available.  This smoke accepts that state but
  checks that compat detection only flips to NeLisp when a complete
  call-site backend (`nelisp-call-process', `nelisp-make-process',
  `nelisp-http-get', `nelisp-http-fetch', or
  `nelisp-http-get-binary') is actually present."
  (and
   (anvil-pkg-nelisp-smoke--load-native-prereqs)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-process-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-network-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-http-source)
   (let ((has-complete-backend
          (or (fboundp 'nelisp-call-process)
              (fboundp 'nelisp-make-process)
              (fboundp 'nelisp-http-get)
              (fboundp 'nelisp-http-fetch)
              (fboundp 'nelisp-http-get-binary)))
         (anvil-pkg-compat--nelisp-backend-require-attempted t))
     (eq (and (anvil-pkg-compat--detect-nelisp-runtime-p) t)
         (and has-complete-backend t)))))

(defun anvil-pkg-nelisp-smoke--native-gap-accounted-p ()
  "Return non-nil when absent native backends match known CLI gaps.

This is not a substitute for a production native backend.  It keeps the
standalone smoke honest by proving that missing async / text HTTP
backends are explained by currently absent evaluator primitives instead
of by an anvil-pkg dispatch regression."
  (and
   (or (anvil-pkg-nelisp-smoke--native-async-lower-primitive-p)
       (not (fboundp 'make-process)))
   (or (anvil-pkg-nelisp-smoke--native-text-http-lower-primitive-p)
       (not (fboundp 'url-retrieve-synchronously)))))

(defun anvil-pkg-nelisp-smoke-capabilities ()
  "Return current standalone NeLisp capabilities relevant to anvil-pkg."
  (anvil-pkg-nelisp-smoke--load-compat)
  (anvil-pkg-nelisp-smoke--load-native-prereqs)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-process-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-network-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-http-source)
  (list :runtime (anvil-pkg-compat-runtime)
        :ert (fboundp 'ert-run-tests-batch-and-exit)
        :ert-shim (fboundp 'anvil-pkg-nelisp-ert--test-body)
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
        (anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p)
        :native-async-lower-primitive
        (anvil-pkg-nelisp-smoke--native-async-lower-primitive-p)
        :native-text-http-lower-primitive
        (anvil-pkg-nelisp-smoke--native-text-http-lower-primitive-p)
        :native-gap-accounted
        (anvil-pkg-nelisp-smoke--native-gap-accounted-p)))

(defun anvil-pkg-nelisp-smoke-suite-readiness ()
  "Return whether the standalone image can run the full ERT suite.

This is an audit result, not the suite itself.  The suite may run with
mocked HTTP paths before standalone NeLisp has production text HTTP
lower primitives, but native async still needs a process lower primitive
because async tests exercise that path directly."
  (anvil-pkg-nelisp-smoke--load-compat)
  (anvil-pkg-nelisp-smoke--load-native-prereqs)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-process-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-network-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-http-source)
  (let* ((has-ert (fboundp 'ert-run-tests-batch-and-exit))
         (has-cl-letf (fboundp 'cl-letf))
         (has-async-lower
          (anvil-pkg-nelisp-smoke--native-async-lower-primitive-p))
         (has-text-http-lower
          (anvil-pkg-nelisp-smoke--native-text-http-lower-primitive-p))
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
          :runtime (anvil-pkg-compat-runtime)
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

(defun anvil-pkg-nelisp-smoke-public-entrypoints ()
  "Return whether standalone NeLisp can load Nelix public entry points."
  (anvil-pkg-nelisp-smoke--load-native-prereqs)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-process-source)
  (condition-case err
      (progn
        (anvil-pkg-nelisp-smoke--load-suite-files
         '("anvil-pkg-compat.el"
           "anvil-pkg-state.el"
           "anvil-pkg.el"
           "anvil-pkg-dsl.el"
           "anvil-pkg-import.el"
           "anvil-pkg-emacs.el"
           "nelix.el"
           "nelix-dsl.el"
           "nelix-import.el"
           "nelix-emacs.el"))
        (list :nelix-load t
              :runtime (anvil-pkg-compat-runtime)
              :nelix-install (fboundp 'nelix-install)
              :nelix-define (fboundp 'nelix-define)
              :nelix-render-nix (fboundp 'nelix-render-nix)
              :nelix-import (fboundp 'nelix-import-async-installer)
              :nelix-emacs (fboundp 'nelix-emacs-derive-deps)))
    (error
     (list :nelix-load nil
           :error err
           :runtime (if (fboundp 'anvil-pkg-compat-runtime)
                        (anvil-pkg-compat-runtime)
                      'unknown)))))

(defun anvil-pkg-nelisp-smoke--load-suite-files (files)
  "Load each path in FILES for a standalone suite run."
  (let ((cur files))
    (while cur
      (anvil-pkg-nelisp-smoke--write-progress
       (list :loading (car cur)))
      (load (car cur))
      (setq cur (cdr cur)))))

(defun anvil-pkg-nelisp-smoke-preload-suite-runtime ()
  "Preload runtime sources needed by standalone suite execution.

This is intended for runtime-image/cache creation.  Test files are not
loaded here; callers set `anvil-pkg-nelisp-smoke-suite-test-files' at
execution time and then call `anvil-pkg-nelisp-smoke-run-suite'."
  (anvil-pkg-nelisp-smoke--load-compat)
  (anvil-pkg-nelisp-smoke--load-native-prereqs)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-process-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-network-source)
  (anvil-pkg-nelisp-smoke--load-optional
   anvil-pkg-nelisp-smoke-http-source)
  (anvil-pkg-nelisp-smoke--load-suite-files
   anvil-pkg-nelisp-smoke-suite-source-files)
  (setq anvil-pkg-nelisp-smoke-suite-source-loaded-p t)
  t)

(defun anvil-pkg-nelisp-smoke--write-progress (value)
  "Write standalone suite progress VALUE when a progress file is configured."
  (let ((file (or anvil-pkg-nelisp-smoke-progress-file
                  (and (boundp 'anvil-pkg-nelisp-ert-progress-file)
                       anvil-pkg-nelisp-ert-progress-file)))
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

(defun anvil-pkg-nelisp-smoke-run-suite ()
  "Run the full anvil-pkg ERT suite when standalone readiness passes.

When the current standalone image is not ready, return a plist with
`:suite-run nil' and the readiness blockers.  When it is ready, load
runtime sources, helper scripts, and ERT files, then delegate to
`ert-run-tests-batch-and-exit'."
  (anvil-pkg-nelisp-smoke--write-progress
   (list :phase 'readiness))
  (let ((readiness (anvil-pkg-nelisp-smoke-suite-readiness)))
    (if (not (plist-get readiness :suite-ready))
        (append (list :suite-run nil) readiness)
      (unless anvil-pkg-nelisp-smoke-suite-source-loaded-p
        (anvil-pkg-nelisp-smoke--write-progress
         (list :phase 'load-suite-source))
        (anvil-pkg-nelisp-smoke--load-suite-files
         anvil-pkg-nelisp-smoke-suite-source-files)
        (setq anvil-pkg-nelisp-smoke-suite-source-loaded-p t))
      (anvil-pkg-nelisp-smoke--write-progress
       (list :phase 'load-suite-tests))
      (anvil-pkg-nelisp-smoke--load-suite-files
       anvil-pkg-nelisp-smoke-suite-test-files)
      (anvil-pkg-nelisp-smoke--write-progress
       (list :phase 'run-tests))
      (when anvil-pkg-nelisp-smoke-progress-file
        (setq anvil-pkg-nelisp-ert-progress-file
              anvil-pkg-nelisp-smoke-progress-file))
      (when anvil-pkg-nelisp-smoke-ert-selector
        (setq anvil-pkg-nelisp-ert-selector
              anvil-pkg-nelisp-smoke-ert-selector))
      (if (fboundp 'anvil-pkg-nelisp-ert-run-tests)
          (anvil-pkg-nelisp-ert-run-tests)
        (if (fboundp 'ert-run-tests-batch-and-exit)
            (ert-run-tests-batch-and-exit)
        (append (list :suite-run nil
                      :suite-blocked-by '(ert-batch-runner))
                readiness))))))

(defun anvil-pkg-nelisp-smoke-suite-loadability ()
  "Return whether standalone NeLisp can load configured suite definitions.

This registration-only probe does not claim the suite can execute.  It
loads the configured ERT files with the local ERT shim configured to
retain test names but not test bodies, so NeLisp parser / loader
regressions become visible before the lower process / URL primitives
needed for execution are available."
  (anvil-pkg-nelisp-smoke--load-compat)
  (anvil-pkg-nelisp-smoke--load-native-prereqs)
  (let ((anvil-pkg-compat--nelisp-runtime-p t)
        (anvil-pkg-compat--nelisp-backend-require-attempted t)
        (anvil-pkg-nelisp-ert-register-only t)
        (tests anvil-pkg-nelisp-smoke-suite-test-files))
    (setq anvil-pkg-nelisp-ert--tests nil)
    (condition-case err
        (progn
          (while tests
            (load (car tests))
            (setq tests (cdr tests)))
          (list :suite-loadable t
                :tests (length anvil-pkg-nelisp-ert--tests)
                :register-only t
                :runtime (anvil-pkg-compat-runtime)))
      (error
       (list :suite-loadable nil
             :error err
             :register-only t
             :runtime (anvil-pkg-compat-runtime))))))

(defun anvil-pkg-nelisp-smoke--unsupported-branches-ok-p ()
  "Return non-nil when NeLisp fallback branches are accounted for.
Older standalone images signaled unsupported-runtime for async and
HTTP paths.  Newer images may execute those paths through native or
curl-backed lower primitives.  Both outcomes are acceptable here; a
plain unexpected error is not."
  (let ((anvil-pkg-compat--nelisp-runtime-p t)
        (anvil-pkg-compat--nelisp-backend-require-attempted t)
        (anvil-pkg-compat-curl-program
         "definitely-missing-anvil-pkg-curl")
        (anvil-pkg-compat-nelisp-call-process-function nil)
        (anvil-pkg-compat-nelisp-make-process-function nil)
        (anvil-pkg-compat-nelisp-executable-find-function
         (lambda (_cmd) nil))
        (anvil-pkg-compat-nelisp-http-get-function nil)
        (anvil-pkg-compat-nelisp-http-get-binary-function nil))
    (and
     (memq (condition-case _err
               (progn
                 (anvil-pkg-compat-make-process-async
                  :name "anvil-pkg-smoke"
                  :command (list "sh" "-c" "true"))
                 'executed)
             (anvil-pkg-async-not-supported 'unsupported)
             (error 'error))
           '(executed unsupported))
     (or (fboundp 'nelisp-http-get)
         (memq (condition-case _err
                   (progn
                     (anvil-pkg-compat-http-get "https://example.invalid" 1)
                     'executed)
                 (anvil-pkg-http-not-supported 'unsupported)
                 (error 'error))
               '(executed unsupported)))
     (or (fboundp 'nelisp-http-get-binary)
         (memq (condition-case _err
                   (progn
                     (anvil-pkg-compat-http-get-binary
                      "https://example.invalid" 1)
                     'executed)
                 (anvil-pkg-http-not-supported 'unsupported)
                 (error 'error))
               '(executed unsupported))))))

(defun anvil-pkg-nelisp-smoke--explicit-hooks-ok-p ()
  "Return non-nil when explicit backend hooks dispatch on standalone NeLisp."
  (let ((anvil-pkg-compat--nelisp-runtime-p t)
        (anvil-pkg-compat--nelisp-backend-require-attempted t)
        (anvil-pkg-compat-nelisp-call-process-function
         (lambda (program args)
           (list :exit 0
                 :stdout (format "%S" (list program args))
                 :stderr "")))
        (anvil-pkg-compat-nelisp-make-process-function
         (lambda (&rest plist)
           (list :hook 'async :name (plist-get plist :name))))
        (anvil-pkg-compat-nelisp-getenv-function
         (lambda (var)
           (and (equal var "ANVIL_PKG_SMOKE") "env-hook")))
        (anvil-pkg-compat-nelisp-executable-find-function
         (lambda (cmd)
           (and (equal cmd "curl") "/hook/bin/curl")))
        (anvil-pkg-compat-nelisp-http-get-function
         (lambda (url timeout auth-header)
           (list :status 211
                 :body (format "%S" (list url timeout auth-header)))))
        (anvil-pkg-compat-nelisp-http-get-binary-function
         (lambda (url timeout auth-header)
           (list :status 212
                 :body (format "%S" (list url timeout auth-header))
                 :content-length 5))))
    (and
     (equal (anvil-pkg-compat-call-process "printf" (list "ok"))
            '(:exit 0 :stdout "(\"printf\" (\"ok\"))" :stderr ""))
     (equal (anvil-pkg-compat-make-process-async
             :name "anvil-pkg-smoke-hook"
             :command (list "true"))
            '(:hook async :name "anvil-pkg-smoke-hook"))
     (equal (anvil-pkg-compat-getenv "ANVIL_PKG_SMOKE")
            "env-hook")
     (equal (anvil-pkg-compat-executable-find "curl")
            "/hook/bin/curl")
     (equal (anvil-pkg-compat-http-get
             "https://example.invalid/hook" 3 "Bearer hook")
            '(:status 211
              :body "(\"https://example.invalid/hook\" 3 \"Bearer hook\")"))
     (equal (anvil-pkg-compat-http-get-binary
             "https://example.invalid/hook.tar" 4 "Bearer hook")
            '(:status 212
              :body "(\"https://example.invalid/hook.tar\" 4 \"Bearer hook\")"
              :content-length 5)))))

(defun anvil-pkg-nelisp-smoke-run ()
  "Return a plist result for the minimal standalone NeLisp smoke."
  (anvil-pkg-nelisp-smoke--load-compat)
  (let ((ok t))
    (unless (fboundp 'anvil-pkg-compat-runtime)
      (setq ok nil))
    (when ok
      (unless (memq (anvil-pkg-compat-runtime) '(emacs nelisp))
        (setq ok nil)))
    (when ok
      (unless (equal (anvil-pkg-compat-string-trim " \t\nok\n\t ") "ok")
        (setq ok nil)))
    (when ok
      (unless (equal (anvil-pkg-compat-string-trim nil) "")
        (setq ok nil)))
    (when ok
      (unless (and (fboundp 'anvil-pkg-compat-json-parse)
                   (fboundp 'anvil-pkg-compat-json-serialize))
        (setq ok nil)))
    (when ok
      (unless (anvil-pkg-nelisp-smoke--json-backend-ok-p)
        (setq ok nil)))
    (when ok
      (unless (anvil-pkg-nelisp-smoke--buffer-backend-ok-p)
        (setq ok nil)))
    (when ok
      (unless (anvil-pkg-nelisp-smoke--unsupported-branches-ok-p)
        (setq ok nil)))
    (when ok
      (unless (anvil-pkg-nelisp-smoke--explicit-hooks-ok-p)
        (setq ok nil)))
    (list :smoke-ok ok)))

(provide 'anvil-pkg-nelisp-smoke)
;;; anvil-pkg-nelisp-smoke.el ends here
