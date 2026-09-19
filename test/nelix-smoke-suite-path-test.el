;;; nelix-smoke-suite-path-test.el --- suite paths across layouts -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `nelix-nelisp-smoke-suite-source-files' is written source-tree
;; relative, and one entry carries a "scripts/" prefix.  An installed
;; package has no such directory: dh_elpa flattens everything into
;; elpa-src/nelix-VERSION/, so scripts/nelix-core-render.el arrives as
;; nelix-core-render.el beside the rest.
;;
;; That is what made the packaged smoke die with file-missing on
;; ".../elpa-src/nelix-0.1.0/scripts/nelix-core-render.el" -- the
;; extracted-package gate's failure, and a defect for anyone installing
;; the .deb rather than running from a checkout.

;;; Code:

(require 'ert)
(require 'nelix-nelisp-smoke)

(defmacro nelix-smoke-suite-path-test--in (dir &rest body)
  "Run BODY with `default-directory' at DIR."
  (declare (indent 1))
  `(let ((default-directory (file-name-as-directory ,dir)))
     ,@body))

(ert-deftest nelix-smoke-suite-path-test-source-layout-keeps-the-prefix ()
  "In a checkout the listed path exists and is used as written."
  (let ((root (make-temp-file "nelix-smoke-src-" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "scripts" root) t)
          (write-region "" nil (expand-file-name "scripts/nelix-core-render.el" root))
          (nelix-smoke-suite-path-test--in root
            (should (equal "scripts/nelix-core-render.el"
                           (nelix-nelisp-smoke--resolve-suite-file
                            "scripts/nelix-core-render.el")))))
      (delete-directory root t))))

(ert-deftest nelix-smoke-suite-path-test-installed-layout-uses-the-basename ()
  "In an installed package the flattened name is used instead."
  (let ((root (make-temp-file "nelix-smoke-installed-" t)))
    (unwind-protect
        (progn
          ;; No scripts/ directory at all -- the dh_elpa layout.
          (write-region "" nil (expand-file-name "nelix-core-render.el" root))
          (nelix-smoke-suite-path-test--in root
            (should (equal "nelix-core-render.el"
                           (nelix-nelisp-smoke--resolve-suite-file
                            "scripts/nelix-core-render.el")))))
      (delete-directory root t))))

(ert-deftest nelix-smoke-suite-path-test-missing-file-keeps-the-listed-path ()
  "A file in neither layout resolves to what the list asked for.

The caller then fails naming that path, which is the useful error;
silently substituting a basename that also does not exist would report
a file nobody listed."
  (let ((root (make-temp-file "nelix-smoke-none-" t)))
    (unwind-protect
        (nelix-smoke-suite-path-test--in root
          (should (equal "scripts/nelix-core-render.el"
                         (nelix-nelisp-smoke--resolve-suite-file
                          "scripts/nelix-core-render.el"))))
      (delete-directory root t))))

(ert-deftest nelix-smoke-suite-path-test-top-level-entries-are-untouched ()
  "An entry with no directory part is returned as-is either way."
  (let ((root (make-temp-file "nelix-smoke-top-" t)))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "nelix-core.el" root))
          (nelix-smoke-suite-path-test--in root
            (should (equal "nelix-core.el"
                           (nelix-nelisp-smoke--resolve-suite-file "nelix-core.el")))))
      (delete-directory root t))))

(ert-deftest nelix-smoke-suite-path-test-render-is-shipped-by-debian ()
  "debian/elpa-nelix.elpa ships the file the suite list needs.

Resolving the path is only half of it: the flattened name has to exist
in the package, and this entry was simply absent."
  (let ((manifest (expand-file-name
                   "debian/elpa-nelix.elpa"
                   (locate-dominating-file
                    (or load-file-name buffer-file-name default-directory)
                    "debian"))))
    (skip-unless (file-exists-p manifest))
    (should (string-match-p
             "scripts/nelix-core-render\\.el"
             (with-temp-buffer (insert-file-contents manifest) (buffer-string))))))

(defvar nelix-smoke-suite-path-test--loaded nil
  "Set by the fixture the load-path test loads.
Declared at top level: a `defvar\=' inside the `let\=' comes too late to
make the binding dynamic, so the loaded file would set a different
variable than the one asserted on -- and the test would fail while the
code under test worked.")

(ert-deftest nelix-smoke-suite-path-test-load-falls-back-via-load-path ()
  "A prefixed entry reachable only through `load-path\=' still loads.

This is the installed case as it actually behaves: `load\=' searches
`load-path\=', `file-exists-p\=' does not, so path-level resolution alone
still asked for scripts/nelix-core-render.el and died with
file-missing even once the flattened file was in the package."
  (let ((root (make-temp-file "nelix-smoke-loadpath-" t))
        (cwd (make-temp-file "nelix-smoke-cwd-" t)))
    (unwind-protect
        (progn
          ;; A name nothing else provides.  Using the real
          ;; scripts/nelix-core-render.el here made the test lie: the
          ;; repository root is on `load-path\=' during a test run, so the
          ;; prefixed path resolved to the actual source file and the
          ;; fallback was never exercised.
          (write-region "(setq nelix-smoke-suite-path-test--loaded t)\n" nil
                        (expand-file-name "nelix-smoke-path-fixture.el" root))
          (let ((load-path (cons root load-path))
                (default-directory (file-name-as-directory cwd))
                (nelix-smoke-suite-path-test--loaded nil))
            (nelix-nelisp-smoke--load-suite-file
             "scripts/nelix-smoke-path-fixture.el")
            (should nelix-smoke-suite-path-test--loaded)))
      (delete-directory root t)
      (delete-directory cwd t))))

(provide 'nelix-smoke-suite-path-test)
;;; nelix-smoke-suite-path-test.el ends here
