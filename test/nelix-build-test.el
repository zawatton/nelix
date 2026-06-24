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

(ert-deftest nelix-build-test-package-el-files-el-exclude ()
  "`nelix-build-package-el-files' drops `nelix-build--el-exclude' basenames.
A package that vendors a copy of another package's library in its own
directory (e.g. chatgpt-el ships a top-level `llama.el') can refuse to install
it via the recipe `:el-exclude', so the vendored copy never shadows the real
package on the shared profile load-path."
  (let* ((tmpdir (make-temp-file "nelix-build-elx-" t))
         (nelix-build--dir tmpdir))
    (unwind-protect
        (progn
          (write-region ";; chatgpt" nil (expand-file-name "chatgpt.el" tmpdir))
          (write-region ";; vendored" nil (expand-file-name "llama.el" tmpdir))
          (make-directory (expand-file-name "test" tmpdir) t)
          (write-region ";; t" nil (expand-file-name "test/foo-test.el" tmpdir))
          ;; Without an exclude: chatgpt.el + llama.el kept, test/ dropped.
          (let* ((nelix-build--el-exclude nil)
                 (names (mapcar #'file-name-nondirectory
                                (nelix-build-package-el-files))))
            (should (member "chatgpt.el" names))
            (should (member "llama.el" names))
            (should-not (member "foo-test.el" names)))
          ;; With :el-exclude ("llama.el"): the vendored copy is dropped.
          (let* ((nelix-build--el-exclude '("llama.el"))
                 (names (mapcar #'file-name-nondirectory
                                (nelix-build-package-el-files))))
            (should (member "chatgpt.el" names))
            (should-not (member "llama.el" names))))
      (delete-directory tmpdir t))))

(provide 'nelix-build-test)
;;; nelix-build-test.el ends here
