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
          ;; Probe host privileges separately so product failures still fail.
          (condition-case err
              (make-symbolic-link target link)
            (file-error
             (ert-skip (format "symbolic links are not permitted here: %s"
                               (error-message-string err)))))
          (delete-file link)
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

(ert-deftest nelix-build-test-path-and-tool-env ()
  "Build tool helpers prepend extra paths and expand HOME-relative values.
`nelix-build--path' must keep the hermetic /usr/bin:/bin tail, while
`nelix-build--tool-env-pairs' must turn `nelix-build-tool-env' into
NAME=VALUE strings with tilde expansion."
  (let ((nelix-build-tool-paths '("/opt/extra/bin" "~/.cargo/bin" "" nil))
        (nelix-build-tool-env '(("CARGO_HOME" . "~/.cargo")
                                ("RUSTUP_HOME" . "~/.rustup")
                                ("EMPTY" . "")
                                ("BAD" . 42)
                                nil)))
    (should (equal (nelix-build--path)
                   (mapconcat #'identity
                              (list (directory-file-name
                                     (expand-file-name "/opt/extra/bin"))
                                    (directory-file-name
                                     (expand-file-name "~/.cargo/bin"))
                                    "/usr/bin"
                                    "/bin")
                              ":")))
    (should (equal (nelix-build--tool-env-pairs)
                   (list (concat "CARGO_HOME="
                                 (expand-file-name "~/.cargo"))
                         (concat "RUSTUP_HOME="
                                 (expand-file-name "~/.rustup"))
                         "EMPTY=")))))

(ert-deftest nelix-build-test-extra-data-paths-expands-files-and-dirs ()
  "`:extra-data-paths' entries resolve to files, directories expanding whole.

Carried over from the branch-side resource-copy test when the two
designs converged on main's `:extra-data-paths'.  main shipped the key
and ten recipes use it, but nothing covered the expansion itself."
  (let* ((tmpdir (make-temp-file "nelix-build-resource-" t))
         (nelix-build--dir tmpdir)
         (nelix-build--extra-data-paths '("README.txt" "data")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "data/sub" tmpdir) t)
          (write-region "alpha" nil (expand-file-name "README.txt" tmpdir))
          (write-region "beta" nil (expand-file-name "data/emoji.json" tmpdir))
          (write-region "gamma" nil (expand-file-name "data/sub/more.json" tmpdir))
          (let ((got (sort (mapcar (lambda (f) (file-relative-name f tmpdir))
                                   (nelix-build-package-extra-files))
                           #'string<)))
            ;; A named file comes through as itself; a named directory
            ;; expands to every file under it, recursively.
            (should (equal '("README.txt" "data/emoji.json" "data/sub/more.json")
                           got))))
      (delete-directory tmpdir t))))

(ert-deftest nelix-build-test-extra-data-paths-skips-hidden-and-missing ()
  "Hidden files are left out and a path absent from this checkout is skipped.

The skip matters: a recipe may list a path that only exists in some
upstream versions, and that must not fail the build."
  (let* ((tmpdir (make-temp-file "nelix-build-resource-" t))
         (nelix-build--dir tmpdir)
         (nelix-build--extra-data-paths '("data" "not-in-this-version.json")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "data" tmpdir) t)
          (write-region "keep" nil (expand-file-name "data/keep.json" tmpdir))
          (write-region "hide" nil (expand-file-name "data/.hidden" tmpdir))
          (should (equal '("data/keep.json")
                         (mapcar (lambda (f) (file-relative-name f tmpdir))
                                 (nelix-build-package-extra-files)))))
      (delete-directory tmpdir t))))

(provide 'nelix-build-test)
;;; nelix-build-test.el ends here
