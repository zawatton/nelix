;;; anvil-pkg-nelisp-ert-shim.el --- Minimal ERT shim for NeLisp smoke -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; This is not a replacement for Emacs ERT.  It is the smallest runner
;; needed by `make smoke-nelisp-suite' once standalone NeLisp has enough
;; lower runtime primitives to execute the anvil-pkg tests.

;;; Code:

(defvar anvil-pkg-nelisp-ert--tests nil
  "List of test symbols registered by `ert-deftest'.")

(defvar anvil-pkg-nelisp-ert-register-only nil
  "When non-nil, register test names without retaining test bodies.")

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

(defun anvil-pkg-nelisp-ert--test-body (body)
  "Return BODY without an optional docstring."
  (if (and body (stringp (car body)))
      (cdr body)
    body))

(defun anvil-pkg-nelisp-ert--restore-cl-letf-binding (entry)
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
  "Small subset of `cl-letf' used by anvil-pkg's ERT tests.

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
          (error "anvil-pkg-nelisp-ert-shim: unsupported cl-letf place %S"
                 place)))))
    `(let ((,saved (list ,@(nreverse save-forms))))
       (unwind-protect
           (progn
             ,@(nreverse set-forms)
             ,@body)
         (dolist (entry ,saved)
           (anvil-pkg-nelisp-ert--restore-cl-letf-binding entry))))))

(defmacro should (form)
  "Signal `ert-test-failed' unless FORM is non-nil."
  `(unless ,form
     (signal 'ert-test-failed (list ',form))))

(defmacro should-not (form)
  "Signal `ert-test-failed' unless FORM is nil."
  `(when ,form
     (signal 'ert-test-failed (list ',form))))

(defmacro should-error (form &rest args)
  "Signal `ert-test-failed' unless FORM signals an error.

Only the ERT `:type' keyword is supported from ARGS."
  (let ((type (cadr (memq :type args))))
    `(let ((caught nil))
       (condition-case err
           (progn ,form nil)
         (error (setq caught err)))
       (unless caught
         (signal 'ert-test-failed (list 'should-error ',form)))
       (when ',type
         (let ((conditions (and (consp caught)
                                (get (car caught) 'error-conditions))))
           (unless (or (eq (car caught) ',type)
                       (memq ',type conditions))
             (signal 'ert-test-failed
                     (list 'should-error-type ',type caught)))))
       caught)))

(defmacro ert-deftest (name &rest body)
  "Register NAME as a test with BODY."
  (let ((test-body (anvil-pkg-nelisp-ert--test-body body)))
    (if anvil-pkg-nelisp-ert-register-only
        `(progn
           (put ',name 'ert-test-body nil)
           (unless (memq ',name anvil-pkg-nelisp-ert--tests)
             (setq anvil-pkg-nelisp-ert--tests
                   (cons ',name anvil-pkg-nelisp-ert--tests)))
           ',name)
      `(progn
         (put ',name 'ert-test-body ',test-body)
         (unless (memq ',name anvil-pkg-nelisp-ert--tests)
           (setq anvil-pkg-nelisp-ert--tests
                 (cons ',name anvil-pkg-nelisp-ert--tests)))
         ',name))))

(defun ert-run-tests-batch-and-exit ()
  "Run registered shim tests and return a result plist."
  (let ((tests (nreverse anvil-pkg-nelisp-ert--tests))
        (passed 0)
        (failed 0)
        (failures nil))
    (dolist (test tests)
      (condition-case err
          (progn
            (let ((body (get test 'ert-test-body)))
              (unless body
                (error "test body not registered for %S" test))
              (eval (cons 'progn body)))
            (setq passed (1+ passed)))
        (error
         (setq failed (1+ failed))
         (setq failures (cons (list test err) failures)))))
    (list :suite-run t
          :tests (+ passed failed)
          :passed passed
          :failed failed
          :failures (nreverse failures))))

(provide 'ert)
(provide 'anvil-pkg-nelisp-ert-shim)
;;; anvil-pkg-nelisp-ert-shim.el ends here
