;;; nelix-invoke-env-test.el --- env(1) selection -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify env(1) selection for POSIX invocation.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'nelix-build)

(ert-deftest nelix-invoke-env-test-prefers-usr-bin-env ()
  (cl-letf (((symbol-function 'file-executable-p) (lambda (_) t))
            ((symbol-function 'nelix-compat-executable-find)
             (lambda (&rest _)
               (ert-fail "PATH lookup must not run"))))
    (should (equal (nelix-build--env-program) "/usr/bin/env"))))

(ert-deftest nelix-invoke-env-test-falls-back-to-path-env ()
  (cl-letf (((symbol-function 'file-executable-p) (lambda (_) nil))
            ((symbol-function 'nelix-compat-executable-find)
             (lambda (program)
               (should (equal program "env"))
               "/nix/store/x-coreutils/bin/env")))
    (should (equal (nelix-build--env-program)
                   "/nix/store/x-coreutils/bin/env"))))

(ert-deftest nelix-invoke-env-test-keeps-usr-bin-env-when-nothing-found ()
  (cl-letf (((symbol-function 'file-executable-p) (lambda (_) nil))
            ((symbol-function 'nelix-compat-executable-find) (lambda (&rest _) nil)))
    (should (equal (nelix-build--env-program) "/usr/bin/env"))))

(provide 'nelix-invoke-env-test)
;;; nelix-invoke-env-test.el ends here
