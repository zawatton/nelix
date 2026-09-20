;;; nelix-tar-test.el --- Portable tar arguments -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Probe caching and argument propagation through product and fixture calls.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'nelix-compat)
(require 'nelix-build)
(require 'nelix-builder)
(require 'nelix-emacs)
(require 'nelix-store-test)
(require 'nelix-emacs-test)

(defun nelix-tar-test--probe (response expected)
  "Check RESPONSE yields EXPECTED and is cached, including failures."
  (let ((nelix-compat--tar-extra-args 'unknown)
        (calls 0))
    (cl-letf (((symbol-function 'nelix-compat-call-process)
               (lambda (program args)
                 (should (equal program "tar"))
                 (should (equal args '("--version")))
                 (setq calls (1+ calls))
                 (if (eq response 'missing)
                     (signal 'file-missing '("No tar"))
                   response))))
      (should (equal (nelix-compat-tar-extra-args) expected))
      (should (equal (nelix-compat-tar-extra-args) expected))
      (should (= calls 1)))))

(ert-deftest nelix-tar-test-gnu ()
  (nelix-tar-test--probe '(:exit 0 :stdout "tar (GNU tar) 1.35\n")
                         '("--force-local")))

(ert-deftest nelix-tar-test-bsd ()
  (nelix-tar-test--probe '(:exit 0 :stdout "bsdtar 3.8.1 - libarchive") nil))

(ert-deftest nelix-tar-test-failed ()
  (nelix-tar-test--probe '(:exit 1 :stdout "GNU tar") nil))

(ert-deftest nelix-tar-test-missing ()
  (nelix-tar-test--probe 'missing nil))

(ert-deftest nelix-tar-test-unknown ()
  (nelix-tar-test--probe '(:exit 0 :stdout "unknown tar") nil))

(defun nelix-tar-test--call-sites (version expected)
  "Check all archive calls for VERSION include exactly EXPECTED extras."
  (let ((nelix-compat--tar-extra-args 'unknown)
        (dir (make-temp-file "nelix-tar-test-" t))
        calls)
    (unwind-protect
        (cl-letf (((symbol-function 'nelix-compat-call-process)
                   (lambda (program args)
                     (should (equal program "tar"))
                     (if (equal args '("--version"))
                         (list :exit 0 :stdout version :stderr "")
                       (push args calls)
                       '(:exit 0 :stdout "entry\n" :stderr ""))))
                  ((symbol-function 'nelix-invoke)
                   (lambda (program &rest args)
                     (should (equal program "tar"))
                     (push args calls)))
                  ((symbol-function 'nelix-builder--run)
                   (lambda (program args)
                     (should (equal program "tar"))
                     (push args calls)))
                  ((symbol-function 'executable-find) (lambda (_) "tar"))
                  ((symbol-function 'call-process)
                   (lambda (program _in _out _display &rest args)
                     (should (equal program "tar"))
                     (push args calls)
                     0)))
          (let ((nelix-build--dir dir)
                (nelix-build--source-archive "archive.tar"))
            (nelix-build-unpack-source-archive "ignored"))
          (should (member "--exclude=ignored" (car calls)))
          (nelix-builder--extract-archive
           "archive.tar" dir '(:archive-format tar) '(:strip-components 1))
          (should (member "--strip-components=1" (car calls)))
          (should (equal (nelix-emacs--tar-list "archive.tar.gz") '("entry")))
          (should (equal (nelix-emacs--tar-extract "archive.tar.gz" "entry")
                         "entry\n"))
          (nelix-store-test--make-tar-fixture dir "fixture")
          (nelix-store-test--make-elisp-tar-fixture dir 'fixture-mode)
          (nelix-emacs-test--build-tarball "pkg" '(("pkg.el" . "payload")))
          (should (= (length calls) 7))
          (dolist (args calls)
            (should (= (cl-count "--force-local" args :test #'equal)
                       (if expected 1 0)))))
      (delete-directory dir t))))

(ert-deftest nelix-tar-test-call-sites-gnu ()
  (nelix-tar-test--call-sites "tar (GNU tar) 1.35" t))

(ert-deftest nelix-tar-test-call-sites-bsd ()
  (nelix-tar-test--call-sites "bsdtar 3.8.1 - libarchive" nil))

(provide 'nelix-tar-test)
;;; nelix-tar-test.el ends here
