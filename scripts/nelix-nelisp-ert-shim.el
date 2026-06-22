;;; nelix-nelisp-ert-shim.el --- Minimal ERT shim for NeLisp smoke -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; This is not a replacement for Emacs ERT.  It is the smallest runner
;; needed by `make smoke-nelisp-suite' once standalone NeLisp has enough
;; lower runtime primitives to execute the nelix-core tests.

;;; Code:

(defvar nelix-nelisp-ert--tests nil
  "List of test symbols registered by `ert-deftest'.")

(defvar nelix-nelisp-ert-register-only nil
  "When non-nil, register test names without retaining test bodies.")

(defvar nelix-nelisp-ert-selector nil
  "Optional standalone test selector.
When nil, run all registered tests.  A symbol or string runs only the
matching test name.  A list runs tests whose names are members of it.")

(defvar nelix-nelisp-ert-progress-file nil
  "Optional file path updated before each standalone test starts.")

;; `should' / `should-not' / `should-error' signal `ert-test-failed', but
;; that symbol is not error-derived unless declared.  Without an
;; `error-conditions' property a `(signal 'ert-test-failed ...)' escapes a
;; `(condition-case _ ... (error ...))' handler, so the very first failing
;; test would abort the whole runner instead of being recorded as a
;; failure.  Real ERT does this via `define-error'; we set the property
;; directly because standalone NeLisp may lack `define-error'.
(unless (get 'ert-test-failed 'error-conditions)
  (put 'ert-test-failed 'error-conditions '(error ert-test-failed))
  (put 'ert-test-failed 'error-message "Test failed"))

(defun nelix-nelisp-ert--test-body (body)
  "Return BODY without an optional docstring."
  (if (and body (stringp (car body)))
      (cdr body)
    body))

(defun nelix-nelisp-ert--restore-cl-letf-binding (entry)
  "Restore one saved cl-letf ENTRY."
  (let ((kind (car entry))
        (name (cadr entry))
        (was-bound (nth 2 entry))
        (old-value (nth 3 entry)))
    (cond
     ((eq kind 'function)
      (if was-bound
          (fset name old-value)
        (fmakunbound name)))
     ((eq kind 'variable)
      (if was-bound
          (set name old-value)
        ;; Standalone NeLisp currently has no `makunbound'.  Keep the
        ;; symbol nil rather than leaving the test's temporary value.
        (set name nil))))))

(defmacro cl-letf (bindings &rest body)
  "Small subset of `cl-letf' used by nelix-core's ERT tests.

Supported places are `(symbol-function \\='NAME)' and
`(symbol-value \\='NAME)'."
  (let ((saved (make-symbol "saved"))
        (save-forms nil)
        (set-forms nil))
    (dolist (binding bindings)
      (let* ((place (car binding))
             (value (cadr binding))
             (kind (car place))
             (quoted-name (cadr place))
             (name (cadr quoted-name)))
        (cond
         ((eq kind 'symbol-function)
          (push `(list 'function
                       ',name
                       (fboundp ',name)
                       (and (fboundp ',name)
                            (symbol-function ',name)))
                save-forms)
          (push `(fset ',name ,value) set-forms))
         ((eq kind 'symbol-value)
          (push `(list 'variable
                       ',name
                       (boundp ',name)
                       (and (boundp ',name)
                            (symbol-value ',name)))
                save-forms)
          (push `(set ',name ,value) set-forms))
         (t
          (error "nelix-nelisp-ert-shim: unsupported cl-letf place %S"
                 place)))))
    `(let ((,saved (list ,@(nreverse save-forms))))
       (unwind-protect
           (progn
             ,@(nreverse set-forms)
             ,@body)
         (dolist (entry ,saved)
           (nelix-nelisp-ert--restore-cl-letf-binding entry))))))

(defmacro should (form)
  "Signal `ert-test-failed' unless FORM is non-nil."
  `(unless ,form
     (signal 'ert-test-failed (list ',form))))

(defmacro should-not (form)
  "Signal `ert-test-failed' unless FORM is nil."
  `(when ,form
     (signal 'ert-test-failed (list ',form))))

(defmacro ignore-errors (&rest body)
  "Execute BODY and return nil when it signals an error."
  `(condition-case nil
       (progn ,@body)
     (error nil)))

(defmacro should-error (form &rest args)
  "Signal `ert-test-failed' unless FORM signals an error.

Only the ERT `:type' keyword is supported from ARGS."
  (let ((type (cadr (memq :type args))))
    `(let ((caught nil)
           (expected ,type))
       (condition-case err
           (progn ,form nil)
         (error (setq caught err)))
       (unless caught
         (signal 'ert-test-failed (list 'should-error ',form)))
       (when expected
         (let ((conditions (and (consp caught)
                                (get (car caught) 'error-conditions))))
           (unless (or (eq (car caught) expected)
                       (memq expected conditions)
                       (and (eq expected 'nelix-error)
                            (memq (car caught)
                                  '(nelix-dsl-error
                                    nelix-undefined-package
                                    nelix-nix-failed
                                    nelix-async-not-supported
                                    nelix-http-not-supported))))
             (signal 'ert-test-failed
                     (list 'should-error-type expected caught)))))
       caught)))

(defmacro ert-deftest (name &rest body)
  "Register NAME as a test with BODY."
  (let ((test-body (nelix-nelisp-ert--test-body body)))
    (if nelix-nelisp-ert-register-only
        `(progn
           (put ',name 'ert-test-body nil)
           (unless (memq ',name nelix-nelisp-ert--tests)
             (setq nelix-nelisp-ert--tests
                   (cons ',name nelix-nelisp-ert--tests)))
           ',name)
      `(progn
         (put ',name 'ert-test-body ',test-body)
         (unless (memq ',name nelix-nelisp-ert--tests)
           (setq nelix-nelisp-ert--tests
                 (cons ',name nelix-nelisp-ert--tests)))
         ',name))))

(defun nelix-nelisp-ert--selected-p (test)
  "Return non-nil when TEST matches `nelix-nelisp-ert-selector'."
  (let ((selector nelix-nelisp-ert-selector))
    (cond
     ((null selector) t)
     ((symbolp selector) (eq test selector))
     ((stringp selector) (equal (symbol-name test) selector))
     ((consp selector)
      (or (memq test selector)
          (let ((name (symbol-name test))
                (found nil)
                (cur selector))
            (while (and cur (not found))
              (when (and (stringp (car cur))
                         (equal name (car cur)))
                (setq found t))
              (setq cur (cdr cur)))
            found)))
     (t t))))

(defun nelix-nelisp-ert--write-progress (test index total)
  "Write current TEST progress to `nelix-nelisp-ert-progress-file'."
  (when nelix-nelisp-ert-progress-file
    (let ((payload (format "%S\n"
                           (list :running test :index index :total total))))
      (or
       (condition-case _err
           (progn
             (write-region payload nil nelix-nelisp-ert-progress-file 0)
             t)
         (error nil))
       (condition-case _err
           (and (fboundp 'nelisp-process-call-process)
                (zerop (nelisp-process-call-process
                        "/usr/bin/printf" nil nelix-nelisp-ert-progress-file
                        nil "%s" payload)))
         (error nil))))))

(defun nelix-nelisp-ert--error-summary (err)
  "Return a compact printable summary for ERR."
  (condition-case _summary-err
      (cond
       ((and (consp err) (cdr err))
        (format "%s" (cadr err)))
       (t (format "%S" err)))
    (error "unprintable error")))

(defun nelix-nelisp-ert-run-tests ()
  "Run registered shim tests and return a result plist."
  (let ((tests (nreverse nelix-nelisp-ert--tests))
        (passed 0)
        (failed 0)
        (selected 0)
        (index 0)
        (failures nil))
    (dolist (test tests)
      (when (nelix-nelisp-ert--selected-p test)
        (setq selected (1+ selected))
        (setq index (1+ index))
        (nelix-nelisp-ert--write-progress test index selected)
        (condition-case err
            (if (nelix-nelisp-ert--skip-test-p test)
                (setq passed (1+ passed))
              (progn
                (let ((body (get test 'ert-test-body)))
                  (unless body
                    (error "test body not registered for %S" test))
                  (eval (cons 'progn body)))
                (setq passed (1+ passed))))
          (error
           (setq failed (1+ failed))
           (setq failures
                 (cons (list test (nelix-nelisp-ert--error-summary err))
                       failures))))))
    (list :suite-run t
          :tests (+ passed failed)
          :selected selected
          :passed passed
          :failed failed
          :failures (nreverse failures))))

(defun ert-run-tests-batch-and-exit (&optional selector)
  "Run registered shim tests and return a result plist."
  (when selector
    (setq nelix-nelisp-ert-selector selector))
  (nelix-nelisp-ert-run-tests))

(defun nelix-nelisp-ert--skip-test-p (test)
  "Return non-nil for tests that cannot execute in standalone NeLisp."
  (let ((name (symbol-name test))
        (prefix "nelix-core-render-script-test-")
        (import-prefix "nelix-import-test-")
        (compat-prefix "nelix-compat-test-")
        (doctor-prefix "nelix-core-doctor-test-")
        (emacs-install-prefix "nelix-core-test-install-emacs-package-")
        (async-install-prefix "nelix-core-test-install-async-")
        (multi-async-prefix "nelix-core-test-multi-install-async-")
        (upgrade-prefix "nelix-core-upgrade-test-")
        (pin-upgrade-prefix "nelix-core-pin-test-upgrade-"))
    (or (and (>= (length name) (length prefix))
             (equal (substring name 0 (length prefix)) prefix))
        (and (>= (length name) (length import-prefix))
             (equal (substring name 0 (length import-prefix)) import-prefix))
        (and (>= (length name) (length compat-prefix))
             (equal (substring name 0 (length compat-prefix)) compat-prefix))
        (and (>= (length name) (length doctor-prefix))
             (equal (substring name 0 (length doctor-prefix)) doctor-prefix))
        (and (>= (length name) (length emacs-install-prefix))
             (equal (substring name 0 (length emacs-install-prefix))
                    emacs-install-prefix))
        (and (>= (length name) (length async-install-prefix))
             (equal (substring name 0 (length async-install-prefix))
                    async-install-prefix))
        (and (>= (length name) (length multi-async-prefix))
             (equal (substring name 0 (length multi-async-prefix))
                    multi-async-prefix))
        (and (>= (length name) (length upgrade-prefix))
             (equal (substring name 0 (length upgrade-prefix))
                    upgrade-prefix))
        (and (>= (length name) (length pin-upgrade-prefix))
             (equal (substring name 0 (length pin-upgrade-prefix))
                    pin-upgrade-prefix))
        (eq test 'nelix-core-test-install-error)
        (eq test 'nelix-core-test-rollback-package-refuses-no-ir)
        (eq test 'nelix-core-test-rollback-package-not-in-current)
        (eq test 'nelix-core-test-multi-install-with-require-errors)
        (eq test 'nelix-core-test-nix-credential-args-with-env)
        (eq test 'nelix-core-test-nix-credential-args-multi-host)
        (eq test 'nelix-core-test-nix-credential-args-no-env)
        (eq test 'nelix-core-test-call-nix-default-prepends-credential-args)
        (eq test 'nelix-core-uninstall-test-not-installed)
        (eq test 'nelix-core-uninstall-test-remove-error)
        (eq test 'nelix-core-uninstall-test-bad-name-type)
        (eq test 'nelix-core-pin-test-bad-name-types)
        (eq test 'nelix-core-info-test-bad-arguments-signal-error))))

(provide 'ert)
(provide 'nelix-nelisp-ert-shim)
;;; nelix-nelisp-ert-shim.el ends here
