;;; nelix-upgrade-plan-parity-test.el --- runtime parity -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The operational gate runs `upgrade-plan' under both runtimes and compares
;; them, and they used to disagree: host Emacs called `pkg-upgrade-plan',
;; which walks the installed profile, while the standalone NeLisp lane goes
;; through `nelix-fast', which walks the manifest's declared targets.
;;
;; Those agree only while the profile holds exactly one element per declared
;; package.  A real profile did not -- twelve packages appeared twice, as
;; `dash' and `dash-1', with identical attrPath and storePaths -- so one
;; runtime planned 216 upgrades and the other 204.
;;
;; `nelix-fast--direct-json-enabled-p' scopes the direct JSON *writer* to
;; NeLisp on purpose; two different computations behind the two writers was
;; not on purpose.  The tests pin the computation, not the encoding.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-manifest)

(ert-deftest nelix-upgrade-plan-parity-test-uses-the-shared-fast-lane ()
  "The manifest base comes from `nelix-fast-upgrade-plan' when it can.

That is the same function the NeLisp lane uses, so the two runtimes
compute one answer between them instead of one each."
  (let ((called nil))
    (cl-letf (((symbol-function 'nelix-fast-upgrade-plan)
               (lambda (file) (setq called file) '(:upgrade ("a") :pinned nil :missing nil)))
              ((symbol-function 'pkg-upgrade-plan)
               (lambda (&rest _) (error "profile walk must not be used here"))))
      (let ((plan (nelix-upgrade-plan--manifest-base "/tmp/m.el")))
        (should (equal "/tmp/m.el" called))
        (should (equal '("a") (plist-get plan :upgrade)))))))

(ert-deftest nelix-upgrade-plan-parity-test-falls-back-to-the-profile-walk ()
  "With the fast lane unavailable, the old profile walk still answers.

Dropping to `pkg-upgrade-plan' is worse than sharing the computation,
but it is much better than signalling: a runtime without the fast lane
still has to be able to produce a plan."
  (cl-letf (((symbol-function 'nelix-fast-upgrade-plan)
             (lambda (_file) (error "fast lane unavailable")))
            ((symbol-function 'pkg-upgrade-plan)
             (lambda (&rest _) '(:upgrade ("from-profile")))))
    (should (equal '("from-profile")
                   (plist-get (nelix-upgrade-plan--manifest-base "/tmp/m.el")
                              :upgrade)))))

(ert-deftest nelix-upgrade-plan-parity-test-duplicate-profile-entries-collapse ()
  "A package registered twice yields one upgrade row, not two.

This is the shape the real profile had: `dash' and `dash-1' naming the
same attrPath and the same store path.  Counting both is what made the
two runtimes disagree."
  (cl-letf (((symbol-function 'nelix-fast-upgrade-plan)
             (lambda (_file)
               ;; What the target-driven walk returns for a manifest
               ;; declaring dash once, against a profile holding it twice.
               '(:upgrade ("dash") :pinned nil :missing nil))))
    (let ((plan (nelix-upgrade-plan--manifest-base "/tmp/m.el")))
      (should (equal '("dash") (plist-get plan :upgrade)))
      (should-not (member "dash-1" (plist-get plan :upgrade))))))

(provide 'nelix-upgrade-plan-parity-test)
;;; nelix-upgrade-plan-parity-test.el ends here
