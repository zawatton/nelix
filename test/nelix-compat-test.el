;;; nelix-compat-test.el --- ERT tests for nelix-compat -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task D coverage for the runtime-aware compat
;; primitives.  Tests do NOT touch the real `nix' binary or attempt
;; cross-runtime spawns — they exercise the dispatch via `cl-letf'
;; on `nelix-compat-runtime'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'url)            ; Phase 4-G: ensure url-retrieve-synchronously is
                          ; a real defun before cl-letf wraps it; otherwise
                          ; the autoload trigger inside http-get-emacs
                          ; overwrites our mock.
(require 'nelix-compat)

(defvar nelix-compat-test--seen nil
  "Scratch variable for ERT backend hook assertions.")

(defvar nelix-nelisp-ert--tests)
(defvar nelix-nelisp-ert-register-only)
(defvar nelix-nelisp-smoke-suite-source-files)
(defvar nelix-nelisp-smoke-suite-test-files)

(declare-function nelix-nelisp-smoke-suite-readiness
                  "scripts/nelix-nelisp-smoke")
(declare-function nelix-nelisp-smoke-suite-loadability
                  "scripts/nelix-nelisp-smoke")
(declare-function nelix-nelisp-smoke-run-suite
                  "scripts/nelix-nelisp-smoke")
(declare-function nelix-nelisp-smoke--curl-process-lower-primitive-p
                  "scripts/nelix-nelisp-smoke")
(declare-function nelix-nelisp-smoke--native-text-http-lower-primitive-p
                  "scripts/nelix-nelisp-smoke")

;;;; --- string utility -------------------------------------------------------

(ert-deftest nelix-compat-test-string-trim-treats-nil-as-empty ()
  "String trim is portable across Emacs and bare NeLisp fallback paths."
  (should (equal "" (nelix-compat-string-trim nil)))
  (should (equal "ok" (nelix-compat-string-trim " \t\nok\n\t "))))

;;;; --- runtime detection ----------------------------------------------------

(ert-deftest nelix-compat-test-detect-nelisp-runtime-with-process ()
  "Runtime detection recognises split NeLisp process primitives."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (eq sym 'nelisp-make-process))))
    (should (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-with-http ()
  "Runtime detection recognises split NeLisp HTTP primitives."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (eq sym 'nelisp-http-get))))
    (should (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-with-http-fetch ()
  "Runtime detection recognises the higher-level NeLisp HTTP package."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (eq sym 'nelisp-http-fetch))))
    (should (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-with-binary-http ()
  "Runtime detection recognises split NeLisp binary HTTP primitives."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (eq sym 'nelisp-http-get-binary))))
    (should (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-no-backend ()
  "Runtime detection stays on Emacs when no NeLisp backend is loaded."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (_sym) nil)))
    (should-not (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-ignores-helper-only-load ()
  "Runtime detection ignores partial NeLisp helper-only loads."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (memq sym '(nelisp-process-get
                           nelisp-process-put
                           nelisp-process-current-status
                           nelisp-process-exit-code-value)))))
    (should-not (nelix-compat--detect-nelisp-runtime-p))))

(ert-deftest nelix-compat-test-detect-nelisp-runtime-lazy-requires ()
  "Runtime detection lazy-requires package-split NeLisp backends once."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-backend-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-http-get)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (memq feature '(nelisp-process nelisp-network))
                   (setq loaded t))
                 feature)))
      (should (nelix-compat--detect-nelisp-runtime-p))
      (should (memq 'nelisp-process requires))
      (should (memq 'nelisp-network requires))
      (should (memq 'nelisp-http requires)))))

(ert-deftest nelix-compat-test-runtime-refreshes-after-backend-load ()
  "Runtime accessor refreshes stale nil detection when a backend appears."
  (let ((nelix-compat--nelisp-runtime-p nil)
        (nelix-compat--nelisp-backend-require-attempted t))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (eq sym 'nelisp-make-process))))
      (should (eq 'nelisp (nelix-compat-runtime)))
      (should nelix-compat--nelisp-runtime-p))))

;;;; --- process object helpers ----------------------------------------------

(ert-deftest nelix-compat-test-process-property-helpers-use-emacs ()
  "Process property helpers use Emacs primitives when available."
  (let ((proc (start-process "nelix-core-props" nil "true")))
    (unwind-protect
        (progn
          (nelix-compat-process-put proc 'key 'value)
          (should (eq 'value
                      (nelix-compat-process-get proc 'key))))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest nelix-compat-test-process-helpers-use-nelisp-wrap ()
  "Process helpers can dispatch to NeLisp process wrapper functions."
  (let ((props nil)
        (proc 'nelisp-proc))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (memq sym '(nelisp-process-get
                             nelisp-process-put
                             nelisp-process-current-status
                             nelisp-process-exit-code-value))))
              ((symbol-function 'nelisp-process-get)
               (lambda (_proc key)
                 (plist-get props key)))
              ((symbol-function 'nelisp-process-put)
               (lambda (_proc key value)
                 (setq props (plist-put props key value))
                 value))
              ((symbol-function 'nelisp-process-current-status)
               (lambda (_proc) 'exit))
              ((symbol-function 'nelisp-process-exit-code-value)
               (lambda (_proc) 7)))
      (should (eq 'v (nelix-compat-process-put proc 'k 'v)))
      (should (eq 'v (nelix-compat-process-get proc 'k)))
      (should (eq 'exit (nelix-compat-process-status proc)))
      (should (eq 7 (nelix-compat-process-exit-status proc))))))

;;;; --- buffer helpers -------------------------------------------------------

(ert-deftest nelix-compat-test-buffer-helpers-use-emacs ()
  "Buffer helpers use Emacs primitives when available."
  (let ((buf (nelix-compat-generate-buffer
              " *nelix-compat-buffer-test*")))
    (unwind-protect
        (progn
          (should (nelix-compat-buffer-live-p buf))
          (with-current-buffer buf
            (insert "stderr"))
          (should (equal "stderr"
                         (nelix-compat-buffer-string buf)))
          (nelix-compat-kill-buffer buf)
          (should-not (nelix-compat-buffer-live-p buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest nelix-compat-test-buffer-helpers-use-nelisp-wrap ()
  "Buffer helpers can dispatch to NeLisp Emacs-compat wrappers."
  (let ((nelix-compat--nelisp-emacs-compat-require-attempted t)
        (created nil)
        (current nil)
        (killed nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (memq sym '(nelisp-ec-generate-new-buffer
                             nelisp-ec-with-current-buffer
                             nelisp-ec-buffer-string
                             nelisp-ec-kill-buffer))))
              ((symbol-function 'nelisp-ec-generate-new-buffer)
               (lambda (name)
                 (setq created name)
                 'nelisp-buffer))
              ((symbol-function 'nelisp-ec-with-current-buffer)
               (lambda (buf value)
                 (setq current buf)
                 value))
              ((symbol-function 'nelisp-ec-buffer-string)
               (lambda () "stderr"))
              ((symbol-function 'nelisp-ec-kill-buffer)
               (lambda (buf)
                 (setq killed buf)
                 t)))
      (should (eq 'nelisp-buffer
                  (nelix-compat-generate-buffer "stderr")))
      (should (equal "stderr" created))
      (should (nelix-compat-buffer-live-p 'nelisp-buffer))
      (should (equal "stderr"
                     (nelix-compat-buffer-string 'nelisp-buffer)))
      (should (eq 'nelisp-buffer current))
      (nelix-compat-kill-buffer 'nelisp-buffer)
      (should (eq 'nelisp-buffer killed)))))

(ert-deftest nelix-compat-test-buffer-string-prefers-nelisp-set-buffer ()
  "Buffer string helper can avoid macro dispatch when set-buffer exists."
  (let ((nelix-compat--nelisp-emacs-compat-require-attempted t)
        (current 'saved-buffer)
        (visited nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (memq sym '(nelisp-ec-current-buffer
                             nelisp-ec-set-buffer
                             nelisp-ec-buffer-string))))
              ((symbol-function 'nelisp-ec-current-buffer)
               (lambda () current))
              ((symbol-function 'nelisp-ec-set-buffer)
               (lambda (buf)
                 (push buf visited)
                 (setq current buf)
                 buf))
              ((symbol-function 'nelisp-ec-buffer-string)
               (lambda () (format "body:%S" current))))
      (should (equal "body:nelisp-buffer"
                     (nelix-compat-buffer-string 'nelisp-buffer)))
      (should (eq 'saved-buffer current))
      (should (equal '(saved-buffer nelisp-buffer) visited)))))

(ert-deftest nelix-compat-test-call-process-refreshes-runtime-before-branch ()
  "call-process dispatch must not read stale runtime detection directly."
  (let ((nelix-compat--nelisp-runtime-p nil)
        (nelix-compat--nelisp-backend-require-attempted t))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (memq sym '(nelisp-call-process
                             generate-new-buffer
                             call-process))))
              ((symbol-function 'nelix-compat--call-process-emacs)
               (lambda (&rest _args)
                 (error "stale Emacs branch selected")))
              ((symbol-function 'nelix-compat--call-process-nelisp)
               (lambda (program args)
                 (list :backend 'nelisp :program program :args args))))
      (should (equal '(:backend nelisp
                       :program "true"
                       :args ("--version"))
                     (nelix-compat-call-process
                      "true" '("--version"))))
      (should nelix-compat--nelisp-runtime-p))))

(ert-deftest nelix-compat-test-call-process-on-nelisp-uses-hook ()
  "call-process delegates to the explicit NeLisp backend hook."
  (let ((nelix-compat-nelisp-call-process-function
         (lambda (program args)
           (list :exit 0
                 :stdout (format "%S" (list program args))
                 :stderr ""))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-call-process)
               (lambda (&rest _args)
                 (error "auto backend used before explicit hook"))))
      (should (equal '(:exit 0
                       :stdout "(\"printf\" (\"ok\"))"
                       :stderr "")
                     (nelix-compat-call-process
                      "printf" (list "ok")))))))

(ert-deftest nelix-compat-test-nelisp-hooks-validate-result-shapes ()
  "Explicit NeLisp backend hooks must return the documented plist shape."
  (cl-letf (((symbol-function 'nelix-compat-runtime)
             (lambda () 'nelisp)))
    (let ((nelix-compat-nelisp-call-process-function
           (lambda (_program _args)
             (list :exit "0" :stdout "" :stderr ""))))
      (should-error (nelix-compat-call-process
                     "printf" (list "ok"))
                    :type 'error))
    (let ((nelix-compat-nelisp-http-get-function
           (lambda (_url _timeout _auth-header)
             (list :status "200" :body ""))))
      (should-error (nelix-compat-http-get
                     "https://example.invalid" 1)
                    :type 'error))
    (let ((nelix-compat-nelisp-http-get-binary-function
           (lambda (_url _timeout _auth-header)
             (list :status 200 :body "" :content-length "0"))))
      (should-error (nelix-compat-http-get-binary
                     "https://example.invalid/archive.tar" 1)
                    :type 'error))))

;;;; --- NeLisp Emacs-compat / fileio lazy require ---------------------------

(ert-deftest nelix-compat-test-executable-find-lazy-requires-nelisp-compat ()
  "PATH lookup probes package-split NeLisp Emacs-compat helpers."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-ec-executable-find)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-ec-executable-find)
               (lambda (cmd)
                 (format "/nelisp/bin/%s" cmd))))
      (should (equal "/nelisp/bin/curl"
                     (nelix-compat-executable-find "curl")))
      (should (memq 'nelisp-emacs-compat requires)))))

(ert-deftest nelix-compat-test-executable-find-falls-back-after-nil ()
  "PATH lookup tries NeLisp compat when an Emacs-compatible shim misses."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (memq sym '(executable-find require))
                     (and loaded (eq sym 'nelisp-ec-executable-find)))))
              ((symbol-function 'executable-find)
               (lambda (_cmd) nil))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-ec-executable-find)
               (lambda (cmd)
                 (format "/nelisp/bin/%s" cmd))))
      (should (equal "/nelisp/bin/git"
                     (nelix-compat-executable-find "git")))
      (should (memq 'nelisp-emacs-compat requires)))))

(ert-deftest nelix-compat-test-executable-find-ignores-stale-nelisp-sys ()
  "PATH lookup avoids stale `nelisp-sys-executable-find' declarations."
  (let ((loaded-ec nil)
        (requires nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (memq sym '(executable-find require nelisp-sys-executable-find))
                     (and loaded-ec (eq sym 'nelisp-ec-executable-find)))))
              ((symbol-function 'executable-find)
               (lambda (_cmd) nil))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat)
                   (setq loaded-ec t))
                 feature))
              ((symbol-function 'nelisp-ec-executable-find)
               (lambda (cmd)
                 (format "/nelisp/bin/%s" cmd))))
      (should (equal "/nelisp/bin/curl"
                     (nelix-compat-executable-find "curl")))
      (should (memq 'nelisp-emacs-compat requires))
      (should-not (memq 'nelisp-sys requires)))))

(ert-deftest nelix-compat-test-executable-find-falls-back-after-stale-fboundp ()
  "PATH lookup tolerates declared but absent NeLisp sys helpers."
  (let ((loaded-ec nil)
        (requires nil)
        ;; Clear the memoized runtime cache so detection runs fresh and
        ;; this test is independent of ERT execution order (the cache is
        ;; a sticky global; see `nelix-compat-runtime').
        (nelix-compat--nelisp-runtime-p nil)
        (nelix-compat--nelisp-backend-require-attempted nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (memq sym '(require nelisp-sys-executable-find))
                     (and loaded-ec (eq sym 'nelisp-ec-executable-find)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat)
                   (setq loaded-ec t))
                 feature))
              ((symbol-function 'nelisp-ec-executable-find)
               (lambda (cmd)
                 (format "/nelisp/bin/%s" cmd))))
      (should (equal "/nelisp/bin/curl"
                     (nelix-compat-executable-find "curl")))
      (should (memq 'nelisp-sys requires))
      (should (memq 'nelisp-emacs-compat requires)))))

(ert-deftest nelix-compat-test-executable-find-on-nelisp-uses-hook ()
  "PATH lookup delegates to the explicit NeLisp backend hook."
  (let ((nelix-compat-nelisp-executable-find-function
         (lambda (cmd)
           (and (equal cmd "curl")
                "/hook/bin/curl"))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'executable-find)
               (lambda (&rest _args)
                 (error "Emacs executable-find used before explicit hook"))))
      (should (equal "/hook/bin/curl"
                     (nelix-compat-executable-find "curl"))))))

(ert-deftest nelix-compat-test-getenv-falls-back-after-nil ()
  "Env lookup tries NeLisp runtime when an Emacs-compatible shim misses."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (memq sym '(getenv require))
                     (and loaded (eq sym 'nelisp-syscall-getenv)))))
              ((symbol-function 'getenv)
               (lambda (_var) nil))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-runtime)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-syscall-getenv)
               (lambda (var)
                 (and (equal var "ANVIL_TEST") "from-nelisp"))))
      (should (equal "from-nelisp"
                     (nelix-compat-getenv "ANVIL_TEST")))
      (should (memq 'nelisp-runtime requires)))))

(ert-deftest nelix-compat-test-getenv-auto-detects-nelisp-sys ()
  "Env lookup tries Doc 44 `nelisp-sys-getenv'."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-backend-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (memq sym '(getenv require))
                     (and loaded (eq sym 'nelisp-sys-getenv)))))
              ((symbol-function 'getenv)
               (lambda (_var) nil))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-sys)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-sys-getenv)
               (lambda (var)
                 (and (equal var "ANVIL_TEST") "from-sys"))))
      (should (equal "from-sys"
                     (nelix-compat-getenv "ANVIL_TEST")))
      (should (memq 'nelisp-sys requires)))))

(ert-deftest nelix-compat-test-getenv-on-nelisp-uses-hook ()
  "Env lookup delegates to the explicit NeLisp backend hook."
  (let ((nelix-compat-nelisp-getenv-function
         (lambda (var)
           (and (equal var "ANVIL_TEST") "from-hook"))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'getenv)
               (lambda (&rest _args)
                 (error "Emacs getenv used before explicit hook"))))
      (should (equal "from-hook"
                     (nelix-compat-getenv "ANVIL_TEST"))))))

(ert-deftest nelix-compat-test-file-exists-lazy-requires-nelisp-fileio ()
  "File existence checks probe package-split NeLisp fileio helpers."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-ec-file-exists-p)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat-fileio)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-ec-file-exists-p)
               (lambda (path)
                 (equal path "/nelisp/state.json"))))
      (should (nelix-compat-file-exists-p "/nelisp/state.json"))
      (should (memq 'nelisp-emacs-compat-fileio requires)))))

(ert-deftest nelix-compat-test-read-file-lazy-requires-nelisp-fileio ()
  "Text reads probe NeLisp fileio before falling back or failing."
  (let ((loaded nil)
        (requires nil)
        (killed nil)
        (seen-path nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded
                          (memq sym '(nelisp-ec-insert-file-contents
                                      nelisp-ec-generate-new-buffer
                                      nelisp-ec-with-current-buffer
                                      nelisp-ec-buffer-string
                                      nelisp-ec-kill-buffer))))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (memq feature '(nelisp-emacs-compat
                                       nelisp-emacs-compat-fileio))
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-ec-generate-new-buffer)
               (lambda (name) (list :buffer name)))
              ((symbol-function 'nelisp-ec-insert-file-contents)
               (lambda (path)
                 (setq seen-path path)
                 :inserted))
              ((symbol-function 'nelisp-ec-buffer-string)
               (lambda () "file-body"))
              ((symbol-function 'nelisp-ec-with-current-buffer)
               (lambda (_buf &rest body-values)
                 (car (last body-values))))
              ((symbol-function 'nelisp-ec-kill-buffer)
               (lambda (buf)
                 (setq killed buf))))
      (should (equal "file-body"
                     (nelix-compat-read-file "/nelisp/state.json")))
      (should (equal "/nelisp/state.json" seen-path))
      (should (equal '(:buffer "*nelix-core-read*") killed))
      (should (memq 'nelisp-emacs-compat-fileio requires)))))

(ert-deftest nelix-compat-test-write-file-lazy-requires-nelisp-fileio ()
  "Text writes probe NeLisp fileio before falling back or failing."
  (let ((loaded nil)
        (requires nil)
        (call nil)
        (nelix-compat--nelisp-emacs-compat-require-attempted nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-ec-write-region)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-emacs-compat-fileio)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-ec-write-region)
               (lambda (&rest args)
                 (setq call args)
                 :ok)))
      (should (eq :ok
                  (nelix-compat-write-file "/nelisp/state.json"
                                               "{\"ok\":true}")))
      (should (equal '("{\"ok\":true}" nil "/nelisp/state.json" nil silent)
                     call))
      (should (memq 'nelisp-emacs-compat-fileio requires)))))

;;;; --- compat-make-process-async (Phase 4-C L22) ---------------------------

(ert-deftest nelix-compat-test-make-process-async-on-nelisp-rejects ()
  "compat-make-process-async signals nelix-async-not-supported on NeLisp.
Verifies the runtime branch in the compat layer (not in
`nelix-core.el') is the rejection point."
  (cl-letf (((symbol-function 'nelix-compat-runtime)
             (lambda () 'nelisp)))
    (let ((nelix-compat-nelisp-make-process-function nil))
      (should-error (nelix-compat-make-process-async
                     :name "nelix-compat-test-rejects"
                     :command '("true")
                     :sentinel #'ignore)
                    :type 'nelix-async-not-supported))))

(ert-deftest nelix-compat-test-make-process-async-on-nelisp-uses-backend ()
  "compat-make-process-async delegates to the Phase 5 NeLisp hook."
  (let ((nelix-compat-nelisp-make-process-function
         (lambda (&rest plist)
           (cons :nelisp-process plist))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp)))
      (should (equal '(:nelisp-process
                       :name "nelix-compat-test-hook"
                       :command ("true")
                       :sentinel ignore)
                     (nelix-compat-make-process-async
                      :name "nelix-compat-test-hook"
                      :command '("true")
                      :sentinel #'ignore))))))

(ert-deftest nelix-compat-test-make-process-async-on-nelisp-auto-detects ()
  "compat-make-process-async uses loaded `nelisp-make-process'."
  (let ((nelix-compat-nelisp-make-process-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-make-process)
               (lambda (&rest plist)
                 (cons :nelisp-make-process plist))))
      (should (equal '(:nelisp-make-process
                       :name "nelix-compat-test-auto"
                       :command ("true")
                       :sentinel ignore)
                     (nelix-compat-make-process-async
                      :name "nelix-compat-test-auto"
                      :command '("true")
                      :sentinel #'ignore))))))

(ert-deftest nelix-compat-test-make-process-async-on-nelisp-auto-error-rejects ()
  "A loaded but unusable NeLisp async backend degrades to unsupported."
  (let ((nelix-compat-nelisp-make-process-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-make-process)
               (lambda (&rest _plist)
                 (error "missing lower make-process primitive"))))
      (should-error (nelix-compat-make-process-async
                     :name "nelix-compat-test-auto-error"
                     :command '("true")
                     :sentinel #'ignore)
                    :type 'nelix-async-not-supported))))

(ert-deftest nelix-compat-test-make-process-async-on-nelisp-lazy-requires ()
  "compat-make-process-async probes NeLisp backends before rejecting."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-backend-require-attempted nil)
        (nelix-compat-nelisp-make-process-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-make-process)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-process)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-make-process)
               (lambda (&rest plist)
                 (cons :nelisp-make-process plist))))
      (should (equal '(:nelisp-make-process
                       :name "nelix-compat-test-lazy"
                       :command ("true")
                       :sentinel ignore)
                     (nelix-compat-make-process-async
                      :name "nelix-compat-test-lazy"
                      :command '("true")
                      :sentinel #'ignore)))
      (should (memq 'nelisp-process requires)))))

(ert-deftest nelix-compat-test-make-process-async-emacs-passthrough ()
  "compat-make-process-async on Emacs returns a real process object.
Spawns `true' so the test does not depend on any external state;
waits via `accept-process-output' so the process is reaped before
the test exits (no resource leak)."
  ;; Default runtime detection on Emacs returns 'emacs; clear the sticky
  ;; memoized runtime cache so detection runs fresh (order-independent).
  (let* ((nelix-compat--nelisp-runtime-p nil)
         (proc (nelix-compat-make-process-async
               :name "nelix-compat-test-passthrough"
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

;;;; --- NeLisp smoke helper -------------------------------------------------

(defun nelix-compat-test--load-nelisp-smoke ()
  "Load the standalone NeLisp smoke helper used by Makefile targets."
  (load (expand-file-name "scripts/nelix-nelisp-smoke.el"
                          default-directory)
        nil :nomessage))

(ert-deftest nelix-nelisp-smoke-test-suite-readiness-reports-blockers ()
  "Suite readiness audit reports actionable blockers when primitives miss."
  (nelix-compat-test--load-nelisp-smoke)
  (cl-letf (((symbol-function 'nelix-nelisp-smoke--load-compat)
             (lambda (&rest _args) t))
            ((symbol-function 'nelix-nelisp-smoke--load-native-prereqs)
             (lambda () t))
            ((symbol-function 'nelix-nelisp-smoke--load-optional)
             (lambda (_path) t))
            ((symbol-function 'nelix-compat-runtime)
             (lambda () 'nelisp))
            ((symbol-function 'fboundp)
             (lambda (sym)
               (memq sym '(nelisp-make-process
                           nelisp-http-get
                           nelisp-http-fetch
                           cl-letf)))))
    (let ((resp (nelix-nelisp-smoke-suite-readiness)))
      (should-not (plist-get resp :suite-ready))
      (should (plist-get resp :readiness-audit-ok))
      (should (equal '(ert-batch-runner
                       native-async-lower-primitive)
                     (plist-get resp :suite-blocked-by)))
      (should-not (plist-get resp :ert))
      (should (plist-get resp :cl-letf))
      (should-not (plist-get resp :make-process))
      (should-not (plist-get resp :url-retrieve-synchronously)))))

(ert-deftest nelix-nelisp-smoke-test-suite-readiness-ready-state ()
  "Suite readiness audit flips ready when suite-required primitives exist."
  (nelix-compat-test--load-nelisp-smoke)
  (cl-letf (((symbol-function 'nelix-nelisp-smoke--load-compat)
             (lambda (&rest _args) t))
            ((symbol-function 'nelix-nelisp-smoke--load-native-prereqs)
             (lambda () t))
            ((symbol-function 'nelix-nelisp-smoke--load-optional)
             (lambda (_path) t))
            ((symbol-function 'nelix-compat-runtime)
             (lambda () 'nelisp))
            ((symbol-function 'fboundp)
             (lambda (sym)
               (memq sym '(ert-run-tests-batch-and-exit
                           make-process
                           cl-letf
                           nelisp-make-process
                           nelisp-http-get)))))
    (let ((resp (nelix-nelisp-smoke-suite-readiness)))
      (should (plist-get resp :suite-ready))
      (should (plist-get resp :readiness-audit-ok))
      (should-not (plist-get resp :suite-blocked-by))
      (should (plist-get resp :ert))
      (should (plist-get resp :cl-letf))
      (should (plist-get resp :native-async-lower-primitive))
      (should-not (plist-get resp :native-text-http-lower-primitive)))))

(ert-deftest nelix-nelisp-smoke-test-compat-curl-lower-primitive ()
  "Smoke accepts curl over the compat PATH lookup."
  (nelix-compat-test--load-nelisp-smoke)
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (memq sym '(nelisp-call-process
                           nelisp-http-get
                           nelix-compat-executable-find))))
            ((symbol-function 'nelix-compat-executable-find)
             (lambda (cmd)
               (and (equal cmd "curl") "/compat/bin/curl"))))
    (should (eq t
                (nelix-nelisp-smoke--curl-process-lower-primitive-p)))
    (should (eq t
                (nelix-nelisp-smoke--native-text-http-lower-primitive-p)))))

(ert-deftest nelix-nelisp-smoke-test-run-suite-stops-when-blocked ()
  "Full suite runner reports blockers without loading tests when unready."
  (nelix-compat-test--load-nelisp-smoke)
  (cl-letf (((symbol-function 'nelix-nelisp-smoke-suite-readiness)
             (lambda ()
               '(:suite-ready nil
                 :suite-blocked-by (ert-batch-runner)
                 :readiness-audit-ok t)))
            ((symbol-function 'nelix-nelisp-smoke--load-suite-files)
             (lambda (&rest _args)
               (error "suite files loaded before readiness"))))
    (let ((resp (nelix-nelisp-smoke-run-suite)))
      (should-not (plist-get resp :suite-run))
      (should (equal '(ert-batch-runner)
                     (plist-get resp :suite-blocked-by))))))

(ert-deftest nelix-nelisp-smoke-test-run-suite-delegates-when-ready ()
  "Full suite runner loads configured files and delegates to ERT."
  (nelix-compat-test--load-nelisp-smoke)
  (let ((loaded nil))
    (cl-letf (((symbol-function 'nelix-nelisp-smoke-suite-readiness)
               (lambda ()
                 '(:suite-ready t :readiness-audit-ok t)))
              ((symbol-function 'nelix-nelisp-smoke--load-suite-files)
               (lambda (files)
                 (push files loaded)))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (eq sym 'ert-run-tests-batch-and-exit)))
              ((symbol-function 'ert-run-tests-batch-and-exit)
               (lambda () :ert-run)))
      (should (eq :ert-run (nelix-nelisp-smoke-run-suite)))
      (should (equal (list nelix-nelisp-smoke-suite-test-files
                           nelix-nelisp-smoke-suite-source-files)
                     loaded)))))

(ert-deftest nelix-nelisp-smoke-test-suite-loadability-registers-only ()
  "Suite loadability uses registration-only ERT mode and reports count."
  (nelix-compat-test--load-nelisp-smoke)
  (let ((nelix-nelisp-smoke-suite-source-files '("src-a" "src-b"))
        (nelix-nelisp-smoke-suite-test-files '("test-a"))
        (nelix-nelisp-ert--tests nil)
        (nelix-nelisp-ert-register-only nil)
        (loaded nil)
        (nelisp-runtime-seen nil)
        (register-only-seen nil))
    (cl-letf (((symbol-function 'nelix-nelisp-smoke--load-compat)
               (lambda (&rest _args) t))
              ((symbol-function 'nelix-nelisp-smoke--load-native-prereqs)
               (lambda () t))
              ((symbol-function 'load)
               (lambda (file &rest _args)
                 (push file loaded)
                 (when (equal file "test-a")
                   (setq register-only-seen
                         nelix-nelisp-ert-register-only)
                   (setq nelisp-runtime-seen
                         nelix-compat--nelisp-runtime-p)
                   (setq nelix-nelisp-ert--tests
                         '(test-a-1 test-a-2)))))
              ((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp)))
      (let ((resp (nelix-nelisp-smoke-suite-loadability)))
        (should (plist-get resp :suite-loadable))
        (should (plist-get resp :register-only))
        (should register-only-seen)
        (should nelisp-runtime-seen)
        (should (equal 2 (plist-get resp :tests)))
        (should (eq 'nelisp (plist-get resp :runtime)))
        (should (equal '("test-a") loaded))))))

;;;; --- Phase 4-G: credentials + masking + http-get auth header --------------

(defmacro nelix-compat-test--with-env (bindings &rest body)
  "Evaluate BODY with BINDINGS env vars set; restore on exit.
BINDINGS is a list of (NAME VALUE) pairs.  VALUE nil unsets."
  (declare (indent 1))
  `(let ((nelix-compat-test--saved
          (mapcar (lambda (b) (cons (car b) (getenv (car b))))
                  ',bindings)))
     (unwind-protect
         (progn
           ,@(mapcar (lambda (b) `(setenv ,(car b) ,(cadr b)))
                     bindings)
           ,@body)
       (dolist (s nelix-compat-test--saved)
         (setenv (car s) (cdr s))))))

(ert-deftest nelix-compat-test-credential-for-url-github-uses-github-token ()
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "ghp_aaa")
                                    ("GH_TOKEN" nil))
    (should (equal "Bearer ghp_aaa"
                   (nelix-compat-credential-for-url
                    "https://github.com/owner/repo")))))

(ert-deftest nelix-compat-test-credential-for-url-fallback-to-gh-token ()
  (nelix-compat-test--with-env (("GITHUB_TOKEN" nil)
                                    ("GH_TOKEN" "gho_bbb"))
    (should (equal "Bearer gho_bbb"
                   (nelix-compat-credential-for-url
                    "https://raw.githubusercontent.com/owner/repo/HEAD/x.el")))))

(ert-deftest nelix-compat-test-credential-for-url-no-env-returns-nil ()
  (nelix-compat-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil))
    (should-not (nelix-compat-credential-for-url
                 "https://github.com/owner/repo"))))

(ert-deftest nelix-compat-test-credential-for-url-unknown-host-returns-nil ()
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "ghp_zzz"))
    (should-not (nelix-compat-credential-for-url
                 "https://example.com/x"))))

(ert-deftest nelix-compat-test-credential-for-url-empty-token-skipped ()
  "Empty env var must not produce a Bearer header."
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "") ("GH_TOKEN" nil))
    (should-not (nelix-compat-credential-for-url
                 "https://github.com/owner/repo"))))

(ert-deftest nelix-compat-test-mask-credentials-redacts-bearer ()
  (should (equal "before Bearer *** after"
                 (nelix-compat-mask-credentials
                  "before Bearer ghp_xyz123 after"))))

(ert-deftest nelix-compat-test-mask-credentials-redacts-extra-access-tokens ()
  (let ((masked (nelix-compat-mask-credentials
                 "--option extra-access-tokens \"github.com=ghp_xyz\"")))
    (should (string-match-p "github.com=\\*\\*\\*" masked))
    (should-not (string-match-p "ghp_xyz" masked))))

(ert-deftest nelix-compat-test-mask-credentials-redacts-x-access-token ()
  (should (equal "https://x-access-token:***@github.com/owner/repo"
                 (nelix-compat-mask-credentials
                  "https://x-access-token:ghp_xyz@github.com/owner/repo"))))

(ert-deftest nelix-compat-test-mask-credentials-leaves-clean-strings ()
  (let ((s "no secrets here"))
    (should (equal s (nelix-compat-mask-credentials s)))))

(ert-deftest nelix-compat-test-http-get-injects-auth-header-from-env ()
  "When GITHUB_TOKEN is set, host-based lookup injects Authorization."
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "ghp_xyz") ("GH_TOKEN" nil))
    (let ((nelix-compat--nelisp-runtime-p nil)
          (seen-headers nil))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (nelix-compat-http-get "https://github.com/owner/repo")
        (should (assoc "Authorization" seen-headers))
        (should (equal "Bearer ghp_xyz"
                       (cdr (assoc "Authorization" seen-headers))))))))

(ert-deftest nelix-compat-test-http-get-no-env-no-header ()
  (nelix-compat-test--with-env (("GITHUB_TOKEN" nil) ("GH_TOKEN" nil))
    (let ((nelix-compat--nelisp-runtime-p nil)
          (seen-headers t))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (nelix-compat-http-get "https://github.com/owner/repo")
        (should-not (assoc "Authorization" seen-headers))))))

(ert-deftest nelix-compat-test-http-get-explicit-auth-header-overrides-env ()
  "Explicit AUTH-HEADER arg wins over env-var auto-detect."
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "from_env"))
    (let ((nelix-compat--nelisp-runtime-p nil)
          (seen-headers nil))
      (cl-letf (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (defvar url-request-extra-headers)
                   (setq seen-headers
                         (and (boundp 'url-request-extra-headers)
                              url-request-extra-headers))
                   nil)))
        (nelix-compat-http-get
         "https://github.com/owner/repo" 5 "Bearer explicit_value")
        (should (equal "Bearer explicit_value"
                       (cdr (assoc "Authorization" seen-headers))))))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-rejects-without-backend ()
  "compat-http-get rejects on NeLisp when no native backend or curl exists."
  (let ((nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-executable-find)
               (lambda (_cmd) nil)))
      (should-error (nelix-compat-http-get "https://example.com/x")
                    :type 'nelix-http-not-supported))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-curl-fallback ()
  "compat-http-get uses the curl fallback when no text backend exists."
  (let ((nelix-compat-nelisp-http-get-function nil)
        (seen nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat--http-get-binary-curl)
               (lambda (url timeout auth-header)
                 (setq seen (list url timeout auth-header))
                 (list :status 202 :body "curl-body" :content-length 9))))
      (should (equal '(:status 202 :body "curl-body")
                     (nelix-compat-http-get
                      "https://example.com/x" 7 "Bearer explicit")))
      (should (equal '("https://example.com/x" 7 "Bearer explicit")
                     seen)))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-native-zero-falls-back-to-curl ()
  "A loaded but unusable NeLisp text HTTP backend can fall back to curl."
  (let ((nelix-compat-nelisp-http-get-function nil)
        (seen nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get)
               (lambda (&rest _args)
                 (list :status 0 :body "")))
              ((symbol-function 'nelix-compat--http-get-curl)
               (lambda (url timeout auth-header)
                 (setq seen (list url timeout auth-header))
                 (list :status 203 :body "curl-after-native-zero"))))
      (should (equal '(:status 203 :body "curl-after-native-zero")
                     (nelix-compat-http-get
                      "https://example.com/x" 8 "Bearer explicit")))
      (should (equal '("https://example.com/x" 8 "Bearer explicit")
                     seen)))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-native-zero-keeps-response-without-curl ()
  "Native text HTTP status 0 is preserved when curl is unavailable."
  (let ((nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get)
               (lambda (&rest _args)
                 (list :status 0 :body "")))
              ((symbol-function 'nelix-compat--http-get-curl)
               (lambda (&rest _args)
                 (signal 'nelix-http-not-supported
                         (list "no curl")))))
      (should (equal '(:status 0 :body "")
                     (nelix-compat-http-get
                      "https://example.com/x" 8 "Bearer explicit"))))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-curl-no-process-rejects ()
  "compat-http-get preserves unsupported when curl cannot be spawned."
  (let ((nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-executable-find)
               (lambda (_cmd) "/usr/bin/curl"))
              ((symbol-function 'nelix-compat-call-process)
               (lambda (&rest _args)
                 (error "no call-process backend available"))))
      (should-error (nelix-compat-http-get "https://example.com/x")
                    :type 'nelix-http-not-supported))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-uses-backend ()
  "compat-http-get delegates to the Phase 5 NeLisp hook with auth."
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "ghp_hook")
                                    ("GH_TOKEN" nil))
    (let ((nelix-compat-nelisp-http-get-function
           (lambda (url timeout auth-header)
             (list :status 200
                   :body "ok"
                   :url url
                   :timeout timeout
                   :auth auth-header))))
      (cl-letf (((symbol-function 'nelix-compat-runtime)
                 (lambda () 'nelisp)))
        (should (equal '(:status 200
                         :body "ok"
                         :url "https://github.com/owner/repo"
                         :timeout 9
                         :auth "Bearer ghp_hook")
                       (nelix-compat-http-get
                        "https://github.com/owner/repo" 9)))))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-auto-detects ()
  "compat-http-get uses loaded `nelisp-http-get' when no hook is set."
  (nelix-compat-test--with-env (("GITHUB_TOKEN" "ghp_auto")
                                    ("GH_TOKEN" nil))
    (let ((nelix-compat-nelisp-http-get-function nil))
      (cl-letf (((symbol-function 'nelix-compat-runtime)
                 (lambda () 'nelisp))
                ((symbol-function 'nelisp-http-get)
                 (lambda (url &rest plist)
                   (list :status 201
                         :body (format "%S" (list url plist))))))
        (let ((resp (nelix-compat-http-get
                     "https://github.com/owner/repo" 11)))
          (should (equal 201 (plist-get resp :status)))
          (should (string-match-p
                   "Authorization.*Bearer ghp_auto"
                   (plist-get resp :body)))
          (should (string-match-p
                   ":timeout 11"
                   (plist-get resp :body))))))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-auto-detects-http-fetch ()
  "compat-http-get uses loaded `nelisp-http-fetch' when network GET is absent."
  (let ((nelix-compat-nelisp-http-get-function nil)
        (seen-plist nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (eq sym 'nelisp-http-fetch)))
              ((symbol-function 'nelisp-http-fetch)
               (lambda (url &rest plist)
                 (setq seen-plist plist)
                 (list :status 206
                       :body (format "fetch:%s" url)))))
      (should (equal '(:status 206
                       :body "fetch:https://github.com/owner/repo")
                     (nelix-compat-http-get
                      "https://github.com/owner/repo"
                      12
                      "Bearer explicit")))
      (should (equal 12 (plist-get seen-plist :timeout-sec)))
      (should (equal 0 (plist-get seen-plist :ttl)))
      (should (plist-get seen-plist :no-cache))
      (should (plist-get seen-plist :skip-robots-check))
      (should (equal '(("Authorization" . "Bearer explicit"))
                     (plist-get seen-plist :headers))))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-lazy-requires ()
  "compat-http-get probes NeLisp network backend before rejecting."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-backend-require-attempted nil)
        (nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-http-get)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-network)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-http-get)
               (lambda (url &rest plist)
                 (list :status 203
                       :body (format "%S" (list url plist))))))
      (let ((resp (nelix-compat-http-get
                   "https://example.com/lazy" 13 "Bearer explicit")))
        (should (equal 203 (plist-get resp :status)))
        (should (string-match-p ":timeout 13" (plist-get resp :body)))
        (should (string-match-p "Authorization.*Bearer explicit"
                                (plist-get resp :body))))
      (should (memq 'nelisp-network requires)))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-lazy-requires-http-fetch ()
  "compat-http-get probes the higher-level NeLisp HTTP package too."
  (let ((loaded nil)
        (requires nil)
        (seen-plist nil)
        (nelix-compat--nelisp-backend-require-attempted nil)
        (nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-http-fetch)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-http)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-http-fetch)
               (lambda (_url &rest plist)
                 (setq seen-plist plist)
                 (list :status 207 :body "fetch-body"))))
      (should (equal '(:status 207 :body "fetch-body")
                     (nelix-compat-http-get
                      "https://example.com/fetch" 14 "Bearer explicit")))
      (should (equal 14 (plist-get seen-plist :timeout-sec)))
      (should (equal '(("Authorization" . "Bearer explicit"))
                     (plist-get seen-plist :headers)))
      (should (memq 'nelisp-http requires)))))

(ert-deftest nelix-compat-test-http-get-on-nelisp-auto-detect-errors-degrade ()
  "nelisp-http-get errors degrade to status 0 like Emacs network errors."
  (let ((nelix-compat-nelisp-http-get-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get)
               (lambda (&rest _args)
                 (error "boom"))))
      (should (equal '(:status 0 :body "")
                     (nelix-compat-http-get
                      "https://example.com/fail" 2))))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-uses-backend ()
  "compat-http-get-binary delegates to the Phase 5 NeLisp hook."
  (let ((nelix-compat-nelisp-http-get-binary-function
         (lambda (url timeout auth-header)
           (list :status 200
                 :body "bytes"
                 :content-length 5
                 :url url
                 :timeout timeout
                 :auth auth-header))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp)))
      (should (equal '(:status 200
                       :body "bytes"
                       :content-length 5
                       :url "https://example.com/archive.tar.gz"
                       :timeout 30
                       :auth "Bearer explicit")
                     (nelix-compat-http-get-binary
                      "https://example.com/archive.tar.gz"
                      nil
                      "Bearer explicit"))))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-auto-detects ()
  "compat-http-get-binary uses loaded `nelisp-http-get-binary'."
  (let ((nelix-compat-nelisp-http-get-binary-function nil)
        (seen-plist nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get-binary)
               (lambda (url &rest plist)
                 (setq seen-plist plist)
                 (list :status 202
                       :body "bytes"
                       :content-length 5
                       :url url))))
      (let ((resp (nelix-compat-http-get-binary
                   "https://example.com/archive.tar.gz"
                   17
                   "Bearer explicit")))
        (should (equal 202 (plist-get resp :status)))
        (should (equal "bytes" (plist-get resp :body)))
        (should (equal 5 (plist-get resp :content-length)))
        (should (equal 17 (plist-get seen-plist :timeout)))
        (should (equal '(("Authorization" . "Bearer explicit"))
                       (plist-get seen-plist :headers)))))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-native-zero-falls-back-to-curl ()
  "A loaded but unusable NeLisp binary HTTP backend can fall back to curl."
  (let ((nelix-compat-nelisp-http-get-binary-function nil)
        (seen nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get-binary)
               (lambda (&rest _args)
                 (list :status 0 :body "" :content-length nil)))
              ((symbol-function 'nelix-compat--http-get-binary-curl)
               (lambda (url timeout auth-header)
                 (setq seen (list url timeout auth-header))
                 (list :status 205
                       :body "curl-bytes"
                       :content-length 10))))
      (should (equal '(:status 205
                       :body "curl-bytes"
                       :content-length 10)
                     (nelix-compat-http-get-binary
                      "https://example.com/archive.tar.gz"
                      18
                      "Bearer explicit")))
      (should (equal '("https://example.com/archive.tar.gz"
                       18
                       "Bearer explicit")
                     seen)))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-lazy-requires ()
  "compat-http-get-binary probes NeLisp network before curl fallback."
  (let ((loaded nil)
        (requires nil)
        (seen-plist nil)
        (nelix-compat--nelisp-backend-require-attempted nil)
        (nelix-compat-nelisp-http-get-binary-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-http-get-binary)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-network)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-http-get-binary)
               (lambda (_url &rest plist)
                 (setq seen-plist plist)
                 (list :status 204
                       :body "bytes"
                       :content-length 5)))
              ((symbol-function 'nelix-compat--http-get-binary-curl)
               (lambda (&rest _args)
                 (error "curl fallback selected before native backend"))))
      (should (equal '(:status 204 :body "bytes" :content-length 5)
                     (nelix-compat-http-get-binary
                      "https://example.com/archive.tar.gz"
                      19
                      "Bearer explicit")))
      (should (equal 19 (plist-get seen-plist :timeout)))
      (should (memq 'nelisp-network requires)))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-auto-errors-degrade ()
  "nelisp-http-get-binary errors degrade to status 0 like Emacs errors."
  (let ((nelix-compat-nelisp-http-get-binary-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelisp-http-get-binary)
               (lambda (&rest _args)
                 (error "boom"))))
      (should (equal '(:status 0 :body "" :content-length nil)
                     (nelix-compat-http-get-binary
                      "https://example.com/archive.tar.gz" 3))))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-curl-fallback ()
  "compat-http-get-binary uses curl on NeLisp when no native hook exists."
  (let ((nelix-compat-nelisp-http-get-binary-function nil)
        (seen-args nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-executable-find)
               (lambda (cmd)
                 (and (equal cmd nelix-compat-curl-program)
                      "/usr/bin/curl")))
              ((symbol-function 'nelix-compat-call-process)
               (lambda (_program args)
                 (setq seen-args args)
                 (list :exit 0 :stdout "" :stderr "")))
              ((symbol-function 'nelix-compat-read-file)
               (lambda (_path)
                 (concat "HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n"
                         "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")))
              ((symbol-function 'nelix-compat--read-file-binary)
               (lambda (_path)
                 "bytes")))
      (should (equal '(:status 200 :body "bytes" :content-length 5)
                     (nelix-compat-http-get-binary
                      "https://github.com/owner/archive.tar.gz"
                      12
                      "Bearer explicit")))
      (should (member "-L" seen-args))
      (should (member "--max-time" seen-args))
      (should (member "12" seen-args))
      (should (member "-H" seen-args))
      (should (member "Authorization: Bearer explicit" seen-args)))))

(ert-deftest nelix-compat-test-http-get-binary-curl-fallback-uses-nelisp-hooks ()
  "Curl fallback can run through explicit NeLisp PATH and process hooks."
  (let ((nelix-compat-test--seen nil)
        (nelix-compat-nelisp-http-get-binary-function nil)
        (nelix-compat-nelisp-executable-find-function
         (lambda (cmd)
           (and (equal cmd nelix-compat-curl-program)
                "/hook/bin/curl")))
        (nelix-compat-nelisp-call-process-function
         (lambda (program args)
           (setq nelix-compat-test--seen (cons program args))
           (list :exit 0 :stdout "" :stderr ""))))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-make-temp-file)
               (let ((n 0))
                 (lambda (_prefix)
                   (setq n (1+ n))
                   (format "/tmp/nelix-core-hook-%d" n))))
              ((symbol-function 'nelix-compat-read-file)
               (lambda (_path)
                 "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"))
              ((symbol-function 'nelix-compat--read-file-binary)
               (lambda (_path)
                 "bytes"))
              ((symbol-function 'nelix-compat-delete-file-quietly)
               (lambda (_path) nil)))
      (should (equal '(:status 200 :body "bytes" :content-length 5)
                     (nelix-compat-http-get-binary
                      "https://github.com/owner/archive.tar.gz"
                      12
                      "Bearer explicit")))
      (should (equal "/hook/bin/curl" (car nelix-compat-test--seen)))
      (should (member "--dump-header" (cdr nelix-compat-test--seen)))
      (should (member "/tmp/nelix-core-hook-1"
                      (cdr nelix-compat-test--seen)))
      (should (member "--output" (cdr nelix-compat-test--seen)))
      (should (member "/tmp/nelix-core-hook-2"
                      (cdr nelix-compat-test--seen))))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-no-curl-rejects ()
  "compat-http-get-binary preserves unsupported signal when no backend exists."
  (let ((nelix-compat-nelisp-http-get-binary-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-executable-find)
               (lambda (_cmd) nil)))
      (should-error (nelix-compat-http-get-binary
                     "https://example.com/archive.tar.gz")
                    :type 'nelix-http-not-supported))))

(ert-deftest nelix-compat-test-http-get-binary-on-nelisp-no-process-rejects ()
  "curl fallback reports unsupported when no process backend can run curl."
  (let ((nelix-compat-nelisp-http-get-binary-function nil))
    (cl-letf (((symbol-function 'nelix-compat-runtime)
               (lambda () 'nelisp))
              ((symbol-function 'nelix-compat-executable-find)
               (lambda (_cmd) "/usr/bin/curl"))
              ((symbol-function 'nelix-compat-call-process)
               (lambda (&rest _args)
                 (error "no call-process backend available"))))
      (should-error (nelix-compat-http-get-binary
                     "https://example.com/archive.tar.gz")
                    :type 'nelix-http-not-supported))))

;;;; --- JSON serializer ------------------------------------------------------

(ert-deftest nelix-compat-test-json-serialize-uses-emacs-backend ()
  "json serializer uses Emacs json-serialize when available."
  (let ((seen nil))
    (cl-letf (((symbol-function 'json-serialize)
               (lambda (obj &rest args)
                 (setq seen (cons obj args))
                 "emacs-json")))
      (should (equal "emacs-json"
                     (nelix-compat-json-serialize '(:a 1))))
      (should (equal '(:a 1) (car seen)))
      (should (equal '(:null-object :null :false-object :json-false)
                     (cdr seen))))))

(ert-deftest nelix-compat-test-json-serialize-uses-nelisp-backend ()
  "json serializer uses nelisp-json-serialize when json-serialize is absent."
  (cl-letf (((symbol-function 'fboundp)
             (lambda (sym)
               (eq sym 'nelisp-json-serialize)))
            ((symbol-function 'nelisp-json-serialize)
             (lambda (obj &rest _args)
               (format "nelisp:%S" obj))))
    (should (equal "nelisp:(:a 1)"
                   (nelix-compat-json-serialize '(:a 1))))))

(ert-deftest nelix-compat-test-json-parse-lazy-requires-nelisp-json ()
  "json parser lazy-requires package-split NeLisp JSON when needed."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-json-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-json-parse-string)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-json)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-json-parse-string)
               (lambda (str &rest args)
                 (list :str str :args args))))
      (should (equal '(:str "{\"a\":1}"
                       :args (:object-type alist
                              :array-type list
                              :null-object nil
                              :false-object nil))
                     (nelix-compat-json-parse " {\"a\":1} ")))
      (should (memq 'nelisp-json requires)))))

(ert-deftest nelix-compat-test-json-serialize-lazy-requires-nelisp-json ()
  "json serializer lazy-requires package-split NeLisp JSON when needed."
  (let ((loaded nil)
        (requires nil)
        (nelix-compat--nelisp-json-require-attempted nil))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (sym)
                 (or (eq sym 'require)
                     (and loaded (eq sym 'nelisp-json-serialize)))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (push feature requires)
                 (when (eq feature 'nelisp-json)
                   (setq loaded t))
                 feature))
              ((symbol-function 'nelisp-json-serialize)
               (lambda (obj &rest _args)
                 (format "nelisp:%S" obj))))
      (should (equal "nelisp:(:a 1)"
                     (nelix-compat-json-serialize '(:a 1))))
      (should (memq 'nelisp-json requires)))))

(provide 'nelix-compat-test)
;;; nelix-compat-test.el ends here
