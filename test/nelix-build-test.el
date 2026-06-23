;;; nelix-build-test.el --- ERT for nelix-build primitives -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Host ERT for nelix-symlink and nelix-delete-directory primitives.
;; These tests use temp directories and do not require the standalone runtime.

;;; Code:

(require 'ert)
(require 'nelix-compat)
(require 'nelix-build)

(ert-deftest nelix-build-test-symlink ()
  "nelix-symlink creates a symbolic link LINK pointing to TARGET."
  (let* ((tmpdir (make-temp-file "nelix-build-test-" t))
         (nelix-build--out tmpdir)
         (nelix-build--dir tmpdir)
         (target (expand-file-name "target.txt" tmpdir))
         (link   (expand-file-name "link.txt" tmpdir)))
    (unwind-protect
        (progn
          (write-region "hello" nil target)
          (nelix-symlink target link)
          (should (file-symlink-p link))
          (should (equal "hello" (with-temp-buffer
                                   (insert-file-contents link)
                                   (buffer-string)))))
      (delete-directory tmpdir t))))

(ert-deftest nelix-build-test-delete-directory ()
  "nelix-delete-directory recursively removes a directory tree."
  (let* ((tmpdir (make-temp-file "nelix-build-test-" t))
         (nelix-build--out tmpdir)
         (nelix-build--dir tmpdir)
         (subdir (expand-file-name "sub/nested" tmpdir)))
    (unwind-protect
        (progn
          (make-directory subdir t)
          (write-region "x" nil (expand-file-name "sub/nested/f.txt" tmpdir))
          (nelix-delete-directory (expand-file-name "sub" tmpdir))
          (should-not (file-exists-p (expand-file-name "sub" tmpdir))))
      (when (file-exists-p tmpdir)
        (delete-directory tmpdir t)))))

(ert-deftest nelix-build-test-delete-directory-absent ()
  "nelix-delete-directory is a no-op if DIR does not exist."
  (let ((nelix-build--out "/tmp")
        (nelix-build--dir "/tmp"))
    (should-not (nelix-delete-directory "/tmp/nelix-absent-dir-test-xyz-99"))))

(provide 'nelix-build-test)
;;; nelix-build-test.el ends here
