;;; nelix-builder-unpack-test.el --- emacs-package unpack phase -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The `emacs-package' preset claims to build "any elpa/git Emacs package",
;; and two different archive shapes reach its unpack phase:
;;
;;   - a release tarball (elpa, codeload) -- gzipped, everything under one
;;     top-level directory named for the package and its rev;
;;   - `git archive --format=tar' output for a (:type git) source --
;;     uncompressed, NO top-level directory, and named after the source URL
;;     (so it arrives as e.g. arduino-mode.git, with no useful extension).
;;
;; Both are built here from a real git repository rather than hand-rolled,
;; because the first version of this test invented the git case by gzip-less
;; analogy to the tarball -- same wrapper directory, just uncompressed -- and
;; so asserted the shape the code already assumed.  It passed while a real
;; git source unpacked to nothing.

;;; Code:

(require 'ert)
(require 'nelix-build)
(require 'nelix-builder)

(defun nelix-builder-unpack-test--preset-form ()
  "Return the `unpack' phase form of the `emacs-package' preset."
  (let ((preset (cdr (assq 'emacs-package nelix-builder--build-system-presets))))
    (cdr (assq 'unpack preset))))

(defun nelix-builder-unpack-test--git-repo (dir)
  "Create a one-commit git repository under DIR and return its path."
  (let* ((repo (expand-file-name "repo" dir))
         (default-directory (file-name-as-directory repo)))
    (make-directory (expand-file-name "lisp" repo) t)
    (write-region "(provide 'pkg)\n" nil (expand-file-name "pkg.el" repo))
    (write-region "(provide 'pkg-extra)\n" nil
                  (expand-file-name "lisp/pkg-extra.el" repo))
    (dolist (args '(("init" "--quiet")
                    ("config" "user.email" "test@example.invalid")
                    ("config" "user.name" "test")
                    ("add" "-A")
                    ("-c" "commit.gpgsign=false" "commit" "--quiet" "-m" "x")))
      (apply #'call-process "git" nil nil nil args))
    repo))

(defun nelix-builder-unpack-test--git-archive (repo dest)
  "Write `git archive --format=tar' of REPO's HEAD to DEST.
This is exactly what `nelix-fetch--fetch-git-source' produces."
  (let ((default-directory (file-name-as-directory repo)))
    (call-process "git" nil nil nil "archive" "--format=tar"
                  "--output" (expand-file-name dest) "HEAD")))

(defun nelix-builder-unpack-test--release-tarball (repo dest)
  "Write a release-style .tar.gz of REPO's tree to DEST.
Wrapped in one top directory, the way codeload and elpa serve one."
  (let ((default-directory (file-name-as-directory repo)))
    (call-process "git" nil nil nil "archive" "--format=tar.gz"
                  "--prefix=pkg-1.0/"
                  "--output" (expand-file-name dest) "HEAD")))

(defun nelix-builder-unpack-test--tool-dirs ()
  "Return the directories of the archive tools the unpack phase execs.
Locate tar and gzip on the ambient PATH, omitting missing tools and duplicates."
  (delete-dups
   (mapcar #'file-name-directory
           (delq nil (mapcar #'executable-find '("tar" "gzip"))))))

(defun nelix-builder-unpack-test--invoke-usable-p ()
  "Return non-nil when `nelix-invoke' can run a tool on this host.
Mirror its two branches: Windows sets the environment around `call-process'
directly; every other host uses /usr/bin/env, absent in the nix build sandbox."
  (or (eq system-type 'windows-nt) (file-executable-p "/usr/bin/env")))

(defun nelix-builder-unpack-test--unpack (make-archive name)
  "Build an archive with MAKE-ARCHIVE named NAME, unpack it, assert contents."
  (let* ((staging (make-temp-file "nelix-unpack-src-" t))
         (build (make-temp-file "nelix-unpack-build-" t)))
    (unwind-protect
        (let* ((repo (nelix-builder-unpack-test--git-repo staging))
               (archive (expand-file-name name staging)))
          (funcall make-archive repo archive)
          ;; The phase execs tar under hermetic /usr/bin:/bin, where tar and gzip
          ;; may be absent (NixOS), so supply their actual directories.
          (let ((nelix-build--source-archive archive)
                (nelix-build--tar-exclude nil)
                (nelix-build-tool-paths (nelix-builder-unpack-test--tool-dirs)))
            (nelix-builder--run-phase-elisp
             'unpack (nelix-builder-unpack-test--preset-form) build build))
          ;; The source tree itself, not its wrapper, ends up in the build dir.
          (should (file-exists-p (expand-file-name "pkg.el" build)))
          (should (file-exists-p (expand-file-name "lisp/pkg-extra.el" build)))
          (should-not (file-directory-p (expand-file-name "pkg-1.0" build))))
      (delete-directory staging t)
      (delete-directory build t))))

(ert-deftest nelix-builder-unpack-test-wrapped-release-tarball ()
  "A .tar.gz wrapped in one top directory unpacks with the wrapper removed."
  (skip-unless (nelix-builder-unpack-test--invoke-usable-p))
  (nelix-builder-unpack-test--unpack
   #'nelix-builder-unpack-test--release-tarball "pkg-1.0.tar.gz"))

(ert-deftest nelix-builder-unpack-test-unwrapped-git-archive ()
  "A `git archive' tar with no wrapper unpacks intact.

The failure this pins down is silent: strip a component off an archive
that has no wrapper and every member is discarded, leaving an empty
build directory."
  (skip-unless (nelix-builder-unpack-test--invoke-usable-p))
  (nelix-builder-unpack-test--unpack
   #'nelix-builder-unpack-test--git-archive "pkg.git"))

(ert-deftest nelix-builder-unpack-test-empty-install-signals ()
  "The emacs-package install phase refuses to install zero .el files.

Without this the unpack failure above stays invisible: an empty store
entry is created, the profile activates it, and every `require' keeps
resolving to whatever older copy sits further down `load-path'."
  (let* ((build (make-temp-file "nelix-install-empty-" t))
         (out (make-temp-file "nelix-install-out-" t))
         (preset (cdr (assq 'emacs-package nelix-builder--build-system-presets)))
         (form (cdr (assq 'install preset))))
    (unwind-protect
        (let ((nelix-build--pname "pkg")
              (nelix-build--el-exclude nil)
              (nelix-build--extra-data-paths nil))
          (should-error
           (nelix-builder--run-phase-elisp 'install form build out)
           :type 'nelix-error))
      (delete-directory build t)
      (delete-directory out t))))

(provide 'nelix-builder-unpack-test)
;;; nelix-builder-unpack-test.el ends here
