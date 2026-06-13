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
    "scripts/anvil-pkg-render.el")
  "Runtime and helper files loaded before a full standalone suite run.")

(defvar anvil-pkg-nelisp-smoke-suite-test-files
  '("test/anvil-pkg-test.el"
    "test/anvil-pkg-dsl-test.el"
    "test/anvil-pkg-import-test.el"
    "test/anvil-pkg-compat-test.el"
    "test/anvil-pkg-emacs-test.el"
    "test/anvil-pkg-state-test.el")
  "ERT files loaded by a full standalone suite run.")

(unless (fboundp 'declare-function)
  (defmacro declare-function (&rest _ignored) nil))

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
    anvil-pkg-nelisp-smoke-ert-shim-source)
   (anvil-pkg-nelisp-smoke--load-optional
    anvil-pkg-nelisp-smoke-actor-source)))

(defun anvil-pkg-nelisp-smoke--native-async-lower-primitive-p ()
  "Return non-nil when loaded native async has a lower spawn primitive."
  (and (fboundp 'nelisp-make-process)
       (fboundp 'make-process)))

(defun anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p ()
  "Return non-nil when curl can run through Emacs or Doc 44 NeLisp process APIs."
  (and (or (fboundp 'call-process)
           (fboundp 'nelisp-call-process))
       (and
        (condition-case nil
            (or (and (fboundp 'executable-find)
                     (executable-find "curl"))
                (and (fboundp 'nelisp-sys-executable-find)
                     (funcall (symbol-function 'nelisp-sys-executable-find)
                              "curl"))
                (and (fboundp 'anvil-pkg-compat-executable-find)
                     (anvil-pkg-compat-executable-find "curl")))
          (error nil))
        t)))

(defun anvil-pkg-nelisp-smoke--native-text-http-lower-primitive-p ()
  "Return non-nil when loaded native text HTTP has a lower HTTP primitive."
  (and (or (fboundp 'nelisp-http-get)
           (fboundp 'nelisp-http-fetch)
           (fboundp 'nelisp-http-get-binary))
       (or (fboundp 'url-retrieve-synchronously)
           (anvil-pkg-nelisp-smoke--curl-process-lower-primitive-p))))

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

This is an audit result, not the suite itself.  Phase 5 can load the
compat layer under standalone NeLisp, but the current local image still
lacks the ERT batch runner and the lower process / URL primitives that
would make production async and text HTTP execution possible."
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
          (and has-ert has-cl-letf has-async-lower has-text-http-lower))
         (blocked-by nil))
    (unless has-text-http-lower
      (setq blocked-by
            (cons 'native-text-http-lower-primitive blocked-by)))
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

(defun anvil-pkg-nelisp-smoke--load-suite-files (files)
  "Load each path in FILES for a standalone suite run."
  (let ((cur files))
    (while cur
      (load (car cur))
      (setq cur (cdr cur)))))

(defun anvil-pkg-nelisp-smoke-run-suite ()
  "Run the full anvil-pkg ERT suite when standalone readiness passes.

When the current standalone image is not ready, return a plist with
`:suite-run nil' and the readiness blockers.  When it is ready, load
runtime sources, helper scripts, and ERT files, then delegate to
`ert-run-tests-batch-and-exit'."
  (let ((readiness (anvil-pkg-nelisp-smoke-suite-readiness)))
    (if (not (plist-get readiness :suite-ready))
        (append (list :suite-run nil) readiness)
      (anvil-pkg-nelisp-smoke--load-suite-files
       anvil-pkg-nelisp-smoke-suite-source-files)
      (anvil-pkg-nelisp-smoke--load-suite-files
       anvil-pkg-nelisp-smoke-suite-test-files)
      (if (fboundp 'ert-run-tests-batch-and-exit)
          (ert-run-tests-batch-and-exit)
        (append (list :suite-run nil
                      :suite-blocked-by '(ert-batch-runner))
                readiness)))))

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
  "Return non-nil when real NeLisp unsupported branches signal correctly."
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
     (eq (condition-case _err
             (progn
               (anvil-pkg-compat-make-process-async
                :name "anvil-pkg-smoke"
                :command (list "sh" "-c" "true"))
               'not-signaled)
           (anvil-pkg-async-not-supported 'signaled))
         'signaled)
     (or (fboundp 'nelisp-http-get)
         (eq (condition-case _err
                 (progn
                   (anvil-pkg-compat-http-get "https://example.invalid" 1)
                   'not-signaled)
               (anvil-pkg-http-not-supported 'signaled))
             'signaled))
     (or (fboundp 'nelisp-http-get-binary)
         (eq (condition-case _err
                 (progn
                   (anvil-pkg-compat-http-get-binary
                    "https://example.invalid" 1)
                   'not-signaled)
               (anvil-pkg-http-not-supported 'signaled))
             'signaled)))))

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
