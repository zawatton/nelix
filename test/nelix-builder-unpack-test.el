;;; nelix-builder-unpack-test.el --- emacs-package unpack phase -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The `emacs-package' preset claims to build "any elpa/git Emacs package".
;; A git source does not arrive as a .tar.gz: `nelix-fetch--fetch-git-source'
;; produces `git archive --format=tar' output, an UNCOMPRESSED tar whose name
;; is the repository basename (arduino-mode.git), with no extension to go on.
;;
;; So the unpack phase is exercised here against both shapes.  The plain-tar
;; case is the one that mattered: with a gzip-forcing `tar xzf' it fails with
;; "gzip: stdin: not in gzip format", which is what a real `(:type git)'
;; recipe hit.

;;; Code:

(require 'ert)
(require 'nelix-build)
(require 'nelix-builder)

(defun nelix-builder-unpack-test--preset-form ()
  "Return the `unpack' phase form of the `emacs-package' preset."
  (let ((preset (cdr (assq 'emacs-package nelix-builder--build-system-presets))))
    (cdr (assq 'unpack preset))))

(defun nelix-builder-unpack-test--make-archive (dir name compress)
  "Create an archive of a one-file package tree under DIR, named NAME.
With COMPRESS non-nil the archive is gzipped.  Returns the archive path.

The tree has a top directory so that the phase's --strip-components=1
has something to strip, exactly as a real source archive does."
  (let* ((top (expand-file-name "pkg-1.0" dir))
         (archive (expand-file-name name dir)))
    (make-directory top t)
    (write-region "(provide 'pkg)\n" nil (expand-file-name "pkg.el" top))
    (let ((default-directory (file-name-as-directory dir)))
      (nelix-invoke "tar" (if compress "czf" "cf") archive "pkg-1.0"))
    archive))

(defun nelix-builder-unpack-test--run (name compress)
  "Unpack an archive named NAME (COMPRESS: gzipped) and return the build dir."
  (let* ((staging (make-temp-file "nelix-unpack-src-" t))
         (build (make-temp-file "nelix-unpack-build-" t))
         (archive (nelix-builder-unpack-test--make-archive staging name compress)))
    (unwind-protect
        (let ((nelix-build--source-archive archive)
              (nelix-build--tar-exclude nil))
          (nelix-builder--run-phase-elisp
           'unpack (nelix-builder-unpack-test--preset-form) build build)
          ;; --strip-components=1 drops the pkg-1.0 prefix.
          (should (file-exists-p (expand-file-name "pkg.el" build)))
          build)
      (delete-directory staging t)
      (delete-directory build t))))

(ert-deftest nelix-builder-unpack-test-gzipped-tarball ()
  "A .tar.gz source archive unpacks (the elpa/codeload shape)."
  (nelix-builder-unpack-test--run "pkg-1.0.tar.gz" t))

(ert-deftest nelix-builder-unpack-test-plain-tar-from-git ()
  "An uncompressed tar unpacks (the `git archive' shape).

Named like a bare repo -- no .tar suffix -- because that is what
`nelix-fetch-source' writes: the destination basename comes from the
source URL, so a git source lands as e.g. arduino-mode.git."
  (nelix-builder-unpack-test--run "arduino-mode.git" nil))

(provide 'nelix-builder-unpack-test)
;;; nelix-builder-unpack-test.el ends here
