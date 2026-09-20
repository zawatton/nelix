;;; nelix-test-isolate-test.el --- Suite containment regression -*- lexical-binding: t; -*-

;;; Commentary:
;; Do not load the support file here: a missing Makefile hook must fail.

;;; Code:

(require 'ert)
(require 'nelix-store)

(defvar nelix-test-isolate-directory nil)
(defvar nelix-test-isolate-original-environment nil)

(ert-deftest nelix-test-default-roots-are-isolated ()
  "Default store and profile roots must stay within the suite sandbox."
  (should (stringp nelix-test-isolate-directory))
  (should nelix-test-isolate-original-environment)
  (let* ((nelix-store-root nil)
         (nelix-profile-root nil)
         (roots (list (nelix-store-root) (nelix-profile-root)))
         (original-roots
          (let ((process-environment nelix-test-isolate-original-environment))
            (list (nelix-store-root) (nelix-profile-root)))))
    (dolist (root roots)
      (should (file-in-directory-p root nelix-test-isolate-directory))
      (dolist (original original-roots)
        (should-not (equal root original))
        (should-not (file-in-directory-p root original))))))

(provide 'nelix-test-isolate-test)
;;; nelix-test-isolate-test.el ends here
