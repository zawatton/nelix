;;; anvil-pkg-compat-test.el --- ERT tests for anvil-pkg-compat -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 4-C sub-task D coverage for the runtime-aware compat
;; primitives.  Tests do NOT touch the real `nix' binary or attempt
;; cross-runtime spawns — they exercise the dispatch via `cl-letf'
;; on `anvil-pkg-compat-runtime'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-compat)

;;;; --- compat-make-process-async (Phase 4-C L22) ---------------------------

(ert-deftest anvil-pkg-compat-test-make-process-async-on-nelisp-rejects ()
  "compat-make-process-async signals anvil-pkg-async-not-supported on NeLisp.
Verifies the runtime branch in the compat layer (not in
`anvil-pkg.el') is the rejection point."
  (cl-letf (((symbol-function 'anvil-pkg-compat-runtime)
             (lambda () 'nelisp)))
    (should-error (anvil-pkg-compat-make-process-async
                   :name "anvil-pkg-compat-test-rejects"
                   :command '("true")
                   :sentinel #'ignore)
                  :type 'anvil-pkg-async-not-supported)))

(ert-deftest anvil-pkg-compat-test-make-process-async-emacs-passthrough ()
  "compat-make-process-async on Emacs returns a real process object.
Spawns `true' so the test does not depend on any external state;
waits via `accept-process-output' so the process is reaped before
the test exits (no resource leak)."
  ;; Default runtime detection on Emacs returns 'emacs; do not stub.
  (let ((proc (anvil-pkg-compat-make-process-async
               :name "anvil-pkg-compat-test-passthrough"
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

(provide 'anvil-pkg-compat-test)
;;; anvil-pkg-compat-test.el ends here
