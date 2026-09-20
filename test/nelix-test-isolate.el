;;; nelix-test-isolate.el --- Isolate suite data directories -*- lexical-binding: t; -*-

;;; Commentary:
;; Load before any test or product module.  Keep HOME unchanged because tests
;; also exercise tilde expansion.  Child processes inherit these settings.

;;; Code:

(defvar nelix-test-isolate-original-environment (copy-sequence process-environment)
  "Environment before suite isolation, for the containment regression test.")

(defvar nelix-test-isolate-directory (make-temp-file "nelix-test-isolate-" t)
  "Temporary directory containing all default suite stores and profiles.")

(defun nelix-test-isolate-cleanup ()
  "Remove the suite's temporary data directory on normal Emacs exit."
  (when (file-directory-p nelix-test-isolate-directory)
    (delete-directory nelix-test-isolate-directory t)))

(add-hook 'kill-emacs-hook #'nelix-test-isolate-cleanup)
(dolist (variable '("LOCALAPPDATA" "XDG_DATA_HOME" "XDG_STATE_HOME"))
  (setenv variable nelix-test-isolate-directory))

(provide 'nelix-test-isolate)
;;; nelix-test-isolate.el ends here
