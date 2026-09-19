;;; nelix-builder-builtin-dep-test.el --- built-in dependencies -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Recipes name Emacs built-ins among their dependencies -- evil-org,
;; org-roam, vulpea and org-draw all list "org" -- and those have no
;; registry recipe by design.  Before this was recognised, installing any
;; of them failed with "missing dependency recipe org", and the only way
;; through was `nelix-builder-allow-missing-dependencies', which silences
;; every missing dependency including the ones that are genuinely absent.
;;
;; So the property under test is a pair: a built-in is satisfied, AND an
;; unknown name still fails.  Testing only the first would pass just as
;; well against a blanket skip.

;;; Code:

(require 'ert)
(require 'nelix-builder)

(ert-deftest nelix-builder-builtin-dep-test-org-is-host-provided ()
  "`org' counts as provided by the host Emacs."
  (should (nelix-builder--host-provided-dependency-p "org")))

(ert-deftest nelix-builder-builtin-dep-test-unknown-is-not ()
  "A name Emacs does not ship is not treated as provided.

This is the half that keeps the check honest: if it answered t for
everything, a registry gap would install a broken package silently."
  (should-not (nelix-builder--host-provided-dependency-p
               "no-such-package-in-any-emacs")))

(ert-deftest nelix-builder-builtin-dep-test-elpa-copy-does-not-count ()
  "A package merely present on `load-path' is not \"provided by Emacs\".

Detection asks Emacs's own manifest, not `load-path'.  Were it the
latter, a copy in ~/.emacs.d/elpa -- exactly what the native cutover
exists to stop using -- would make any package look built in and its
recipe would be skipped."
  (let* ((dir (make-temp-file "nelix-fake-elpa-" t))
         (load-path (cons dir load-path)))
    (unwind-protect
        (progn
          (write-region "(provide 'totally-not-builtin)\n" nil
                        (expand-file-name "totally-not-builtin.el" dir))
          (should (locate-library "totally-not-builtin"))
          (should-not (nelix-builder--host-provided-dependency-p
                       "totally-not-builtin")))
      (delete-directory dir t))))

(ert-deftest nelix-builder-builtin-dep-test-explicit-list-is-honoured ()
  "`nelix-builder-host-provided-dependencies' covers what detection misses."
  (let ((nelix-builder-host-provided-dependencies '("some-vendored-thing")))
    (should (nelix-builder--host-provided-dependency-p "some-vendored-thing"))))

(defmacro nelix-builder-builtin-dep-test--in-empty-profile (&rest body)
  "Run BODY against a throwaway, empty profile root."
  (declare (indent 0))
  `(let* ((root (make-temp-file "nelix-builtin-dep-" t))
          (nelix-profile-root (expand-file-name "profiles" root))
          (nelix-store-root (expand-file-name "store" root))
          (nelix-builder-allow-missing-dependencies nil))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest nelix-builder-builtin-dep-test-install-skips-builtin ()
  "`--install-dependencies' passes over a built-in without the blanket flag.

The call site, not just the predicate: this is the path that raised
\"nelix-native-install-recipe: missing dependency recipe org\" for six
packages with `nelix-builder-allow-missing-dependencies' left at nil."
  (nelix-builder-builtin-dep-test--in-empty-profile
    (should (null (nelix-builder--install-dependencies
                   '("org") "default" 'x86_64-linux)))))

(ert-deftest nelix-builder-builtin-dep-test-install-still-fails-unknown ()
  "A dependency that is neither built in nor in the registry still errors."
  (nelix-builder-builtin-dep-test--in-empty-profile
    (let ((err (should-error (nelix-builder--install-dependencies
                              '("no-such-package-in-any-emacs")
                              "default" 'x86_64-linux)
                             :type 'nelix-error)))
      (should (string-match-p "missing dependency recipe" (cadr err))))))

(provide 'nelix-builder-builtin-dep-test)
;;; nelix-builder-builtin-dep-test.el ends here
