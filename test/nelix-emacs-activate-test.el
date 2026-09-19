;;; nelix-emacs-activate-test.el --- Doc 33 M5 native activation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 33 section 4.6, the init.el cutover: activation must put the native
;; profile's own directories on `load-path' and load each package's
;; autoloads.
;;
;; Every test builds a real profile on disk through `nelix-profile-write' and
;; real directories under it, rather than stubbing `nelix-profile-read'.  The
;; cases that matter here are the ragged ones -- a store path that no longer
;; exists, an autoloads file that throws -- and a stub would answer those by
;; construction instead of by behaviour.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-store)
(require 'nelix-emacs)

(defmacro nelix-emacs-activate-test--with-profile (entries &rest body)
  "Run BODY with a real native profile whose :entries are ENTRIES.

Binds `root' to the temp root and `load-path' to a private copy so an
activation cannot leak into the test session."
  (declare (indent 1))
  `(let* ((root (make-temp-file "nelix-activate-" t))
          (nelix-profile-root (expand-file-name "profiles" root))
          (nelix-store-root (expand-file-name "store" root))
          (nelix-emacs-activate-profile "default")
          (load-path (copy-sequence load-path)))
     (unwind-protect
         (progn
           (nelix-profile-write-generation
            (list :name "default" :generation 1
                  :system 'x86_64-linux :entries ,entries))
           ,@body)
       (delete-directory root t))))

(defun nelix-emacs-activate-test--pkg (root name &optional autoloads-body)
  "Create a store dir for NAME under ROOT and return an entry plist.
With AUTOLOADS-BODY, write NAME-autoloads.el containing it."
  (let ((dir (expand-file-name (concat "store/" name) root)))
    (make-directory dir t)
    (write-region (format ";;; %s.el\n(provide '%s)\n" name name) nil
                  (expand-file-name (concat name ".el") dir))
    (when autoloads-body
      (write-region autoloads-body nil
                    (expand-file-name (concat name "-autoloads.el") dir)))
    (list :name name :version "0" :store-path dir
          :backend 'nelix-native :emacs-load-paths (list dir))))

;;;; --- the cutover itself ---------------------------------------------------

(ert-deftest nelix-emacs-activate-test-puts-entries-on-load-path ()
  "Activation adds each entry's directory to `load-path'."
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg root "alpha")
            (nelix-emacs-activate-test--pkg root "beta"))
    (let* ((report (nelix-emacs-activate-native))
           (added (plist-get report :paths)))
      (should (= 2 (length added)))
      (dolist (dir added)
        (should (member dir load-path)))
      (should (null (plist-get report :missing)))
      (should (null (plist-get report :errors))))))

(ert-deftest nelix-emacs-activate-test-prepends-over-package-user-dir ()
  "A native entry wins over a same-named copy already on `load-path'.

The whole point of the cutover: on this machine every package resolves
from ~/.emacs.d/elpa because it precedes the profile.  If activation
appended, the native store would stay unused and the cutover would
report success while changing nothing."
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg root "alpha"))
    (let ((elpa (expand-file-name "elpa/alpha" root)))
      (make-directory elpa t)
      (setq load-path (cons elpa load-path))
      (let ((native (car (plist-get (nelix-emacs-activate-native) :paths))))
        (should (< (cl-position native load-path :test #'equal)
                   (cl-position elpa load-path :test #'equal)))))))

(defvar nelix-emacs-activate-test--ran nil
  "Set by the fixture autoloads file so the test can see it ran.
Declared at top level: a `defvar' inside the `let' would come too late
to make the binding dynamic, and the loaded file would then write a
different variable than the one asserted on.")

(ert-deftest nelix-emacs-activate-test-loads-autoloads ()
  "An entry's NAME-autoloads.el is loaded when present."
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg
             root "alpha" "(setq nelix-emacs-activate-test--ran t)\n"))
    (let ((nelix-emacs-activate-test--ran nil))
      (let ((report (nelix-emacs-activate-native)))
        (should (equal '("alpha") (plist-get report :autoloads)))
        (should nelix-emacs-activate-test--ran)))))

(ert-deftest nelix-emacs-activate-test-is-idempotent ()
  "Activating twice does not duplicate `load-path' entries."
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg root "alpha"))
    (nelix-emacs-activate-native)
    (let ((len (length load-path)))
      (nelix-emacs-activate-native)
      (should (= len (length load-path))))))

;;;; --- the ragged cases -----------------------------------------------------

(ert-deftest nelix-emacs-activate-test-skips-vanished-store-path ()
  "A recorded path that no longer exists is reported, not added.

A profile can outlive its store -- collected, or copied from another
machine.  Putting a missing directory on `load-path' costs a stat on
every `require' for the rest of the session."
  (nelix-emacs-activate-test--with-profile
      (list (list :name "ghost" :version "0"
                  :store-path "/nonexistent/nelix/ghost"
                  :backend 'nelix-native
                  :emacs-load-paths '("/nonexistent/nelix/ghost")))
    (let ((report (nelix-emacs-activate-native)))
      (should (null (plist-get report :paths)))
      (should (equal '("ghost") (plist-get report :missing)))
      (should-not (member "/nonexistent/nelix/ghost" load-path)))))

(ert-deftest nelix-emacs-activate-test-broken-autoloads-does-not-abort ()
  "One throwing autoloads file is recorded; the rest still activate.

Activation runs from init.el.  Aborting would leave `load-path'
half-built with nothing saying which package did it."
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg root "bad" "(error \"boom\")\n")
            (nelix-emacs-activate-test--pkg root "good"))
    (let ((report (nelix-emacs-activate-native)))
      (should (= 2 (length (plist-get report :paths))))
      (should (assoc "bad" (plist-get report :errors)))
      (should (string-match-p "boom" (cdr (assoc "bad" (plist-get report :errors)))))
      ;; the good entry is unaffected
      (should-not (assoc "good" (plist-get report :errors))))))

;;;; --- the availability gate ------------------------------------------------

(ert-deftest nelix-emacs-activate-test-available-only-with-entries ()
  "`available-p' is nil for an empty profile and t once it has entries.

A caller keeps its old path when this is nil.  An empty profile that
answered t would activate nothing and report success."
  (nelix-emacs-activate-test--with-profile nil
    (should-not (nelix-emacs-native-profile-available-p)))
  (nelix-emacs-activate-test--with-profile
      (list (nelix-emacs-activate-test--pkg root "alpha"))
    (should (nelix-emacs-native-profile-available-p))))

(ert-deftest nelix-emacs-activate-test-available-nil-without-profile ()
  "A missing profile answers nil rather than signalling."
  (let* ((root (make-temp-file "nelix-activate-none-" t))
         (nelix-profile-root (expand-file-name "profiles" root))
         (nelix-emacs-activate-profile "default"))
    (unwind-protect
        (should-not (nelix-emacs-native-profile-available-p))
      (delete-directory root t))))

(provide 'nelix-emacs-activate-test)
;;; nelix-emacs-activate-test.el ends here
