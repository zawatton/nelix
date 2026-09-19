;;; nelix-backend-system-nixfree-test.el --- Nix-free system lane -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Doc 34 section 5.2: an OS-provided prerequisite that is absent must be
;; reported as an explicit system dependency "rather than silently falling
;; back to a different package universe".
;;
;; These cover the lane that runs with no acquisition provider configured at
;; all -- `nelix-system-backend-policy' empty -- which is what makes a
;; Nix-free profile possible.  With a provider present the delegating path is
;; already covered by `nelix-manifest-test-system-backend-delegates-to-nix-provider'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-backend)

(defmacro nelix-backend-system-test--no-provider (&rest body)
  "Run BODY with no acquisition provider configured."
  (declare (indent 0))
  `(let ((nelix-system-backend-policy nil))
     ,@body))

(defmacro nelix-backend-system-test--with-programs (present &rest body)
  "Run BODY pretending exactly PRESENT program names exist on PATH."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'nelix-compat-executable-find)
              (lambda (cmd) (and (member cmd ,present) (concat "/usr/bin/" cmd)))))
     ,@body))

;;;; --- present on the OS ----------------------------------------------------

(ert-deftest nelix-backend-system-test-present-program-needs-no-provider ()
  "A prerequisite already on PATH installs fine with no provider at all."
  (nelix-backend-system-test--no-provider
    (nelix-backend-system-test--with-programs '("mu")
      (let ((report (nelix-backend-install 'system '("mu") "default"
                                           'x86_64-linux)))
        (should (eq 'system (plist-get report :backend)))
        (should (null (plist-get report :provider)))
        ;; The distinguishing field: satisfied by the OS, not by Nelix.
        (should (eq 'os (plist-get report :satisfied-by)))
        (should (equal '("mu") (plist-get report :programs)))))))

(ert-deftest nelix-backend-system-test-symbol-and-plist-targets ()
  "Targets may be strings, symbols, or rows carrying `:system'/`:name'."
  (nelix-backend-system-test--no-provider
    (nelix-backend-system-test--with-programs '("mu" "gpg" "rg")
      (should (equal '("mu" "gpg" "rg")
                     (plist-get (nelix-backend-install
                                 'system
                                 (list "mu" 'gpg '(:name "ripgrep" :system "rg"))
                                 "default" 'x86_64-linux)
                                :programs))))))

;;;; --- absent on the OS -----------------------------------------------------

(ert-deftest nelix-backend-system-test-absent-program-is-external-dependency ()
  "An absent prerequisite signals `nelix-external-dependency', not a bare error.

The dedicated condition is what lets callers tell \"you must install
this yourself\" apart from a Nelix malfunction."
  (nelix-backend-system-test--no-provider
    (nelix-backend-system-test--with-programs '()
      (let ((err (should-error (nelix-backend-install 'system '("mu") "default"
                                                      'x86_64-linux)
                               :type 'nelix-external-dependency)))
        (should (memq 'nelix-error (get (car err) 'error-conditions)))
        (let ((data (cdr err)))
          (should (equal '("mu") (plist-get (cdr data) :programs)))
          (should (eq 'x86_64-linux (plist-get (cdr data) :system))))))))

(ert-deftest nelix-backend-system-test-message-names-what-to-do ()
  "The message names the program, the policy variable, and both ways out.

This is the text an operator sees, so assert on its content: a message
that says only \"no system provider available\" points nowhere."
  (nelix-backend-system-test--no-provider
    (nelix-backend-system-test--with-programs '()
      (let* ((err (should-error (nelix-backend-install 'system '("mu") "default"
                                                       'x86_64-linux)
                                :type 'nelix-external-dependency))
             (msg (cadr err)))
        (should (string-match-p "`mu'" msg))
        (should (string-match-p "operating system" msg))
        (should (string-match-p "nelix-system-backend-policy" msg))
        (should (string-match-p "OS package manager" msg))))))

(ert-deftest nelix-backend-system-test-reports-every-missing-program ()
  "All absent prerequisites are named at once, not just the first."
  (nelix-backend-system-test--no-provider
    (nelix-backend-system-test--with-programs '("gpg")
      (let* ((err (should-error (nelix-backend-install
                                 'system '("mu" "gpg" "rg") "default"
                                 'x86_64-linux)
                                :type 'nelix-external-dependency))
             (missing (plist-get (cddr err) :programs)))
        (should (equal '("mu" "rg") missing))))))

;;;; --- availability + upgrade ----------------------------------------------

(ert-deftest nelix-backend-system-test-available-without-provider ()
  "`system' stays selectable with no provider, so rows are not skipped.

Reporting it unavailable would make `nelix-backend-select' pass over
system rows silently, which is the fallback Doc 34 rules out."
  (nelix-backend-system-test--no-provider
    (should (nelix-backend-available-p 'system 'x86_64-linux))))

(ert-deftest nelix-backend-system-test-upgrade-plan-does-not-signal ()
  "An OS-provided row yields a plain report, not an error.

Signalling here would let one system row abort an upgrade plan that
covers every other backend."
  (nelix-backend-system-test--no-provider
    (let ((plan (nelix-backend-upgrade-plan 'system '("mu"))))
      (should (eq 'system (plist-get plan :backend)))
      (should (plist-get plan :external-dependency))
      (should (null (plist-get plan :provider-plan))))))

;;;; --- the capability flag --------------------------------------------------

(ert-deftest nelix-backend-system-test-native-declares-build ()
  "`nelix-native' advertises the build capability Doc 34 shipped.

The flag read `nil' long after `nelix-builder' gained the make / cmake
/ cargo presets, and that stale value was read back as \"native cannot
build from source\"."
  (should (plist-get (nelix-backend-capabilities 'nelix-native) :build)))

(provide 'nelix-backend-system-nixfree-test)
;;; nelix-backend-system-nixfree-test.el ends here
