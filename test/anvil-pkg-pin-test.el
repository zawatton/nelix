;;; anvil-pkg-pin-test.el --- ERT tests for package pinning -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 7-A coverage for `pkg-pin', `pkg-unpin', `pkg-list-pins',
;; and pin-aware `pkg-upgrade'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-state)

(defmacro anvil-pkg-pin-test--with-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg--call-nix-fn' bound to MOCK-FN."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "anvil-pkg-pin-test-" nil ".json"))
          (anvil-pkg-state-file tmp)
          (anvil-pkg-state--cache 'unloaded)
          (anvil-pkg-state--loaded-from nil)
          (anvil-pkg--call-nix-fn ,mock-fn)
          (anvil-pkg-nix-channel "nixpkgs")
          (anvil-pkg-profile-dir "/tmp/anvil-pkg-test-profile"))
     (unwind-protect
         (progn
           (delete-file tmp)
           (anvil-pkg-state-clear-all)
           ,@body)
       (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest anvil-pkg-pin-test-pin-then-pinned-p ()
  "`pkg-pin' records a name and `pkg-pinned-p' sees it."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pin APIs must not shell out to nix"))
    (should (eq t (pkg-pin 'ripgrep)))
    (should (eq t (pkg-pinned-p "ripgrep")))))

(ert-deftest anvil-pkg-pin-test-unpin-clears-state ()
  "`pkg-unpin' removes a previously pinned name."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pin APIs must not shell out to nix"))
    (should (eq t (pkg-pin "ripgrep")))
    (should (eq t (pkg-unpin 'ripgrep)))
    (should (null (pkg-pinned-p "ripgrep")))))

(ert-deftest anvil-pkg-pin-test-list-pins-returns-names ()
  "`pkg-list-pins' returns the pinned package names as strings."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pin APIs must not shell out to nix"))
    (pkg-pin 'ripgrep)
    (pkg-pin "magit")
    (should (equal '("magit" "ripgrep")
                   (sort (copy-sequence (pkg-list-pins)) #'string<)))))

(ert-deftest anvil-pkg-pin-test-bad-name-types ()
  "Pin APIs reject unsupported NAME values."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pin APIs must not shell out to nix"))
    (let ((pin-err (should-error (pkg-pin 42) :type 'anvil-pkg-error))
          (unpin-err (should-error (pkg-unpin 42) :type 'anvil-pkg-error))
          (pinned-err (should-error (pkg-pinned-p 42) :type 'anvil-pkg-error)))
      (should (string-match-p "pkg-pin: NAME must be non-empty string or symbol"
                              (cadr pin-err)))
      (should (string-match-p "pkg-unpin: NAME must be non-empty string or symbol"
                              (cadr unpin-err)))
      (should (string-match-p "pkg-pinned-p: NAME must be non-empty string or symbol"
                              (cadr pinned-err))))))

(ert-deftest anvil-pkg-pin-test-upgrade-all-with-no-pins-keeps-dot-star ()
  "pkg-upgrade nil keeps the existing \".*\" matcher when nothing is pinned."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (anvil-pkg-pin-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade nil)))))
    (should (equal (append (list "profile" "upgrade" ".*")
                           (list "--profile" "/tmp/anvil-pkg-test-profile"))
                   captured-args))))

(ert-deftest anvil-pkg-pin-test-upgrade-all-skips-pinned-packages ()
  "pkg-upgrade nil enumerates installed packages minus the pinned ones."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list)
               (lambda ()
                 (list (list :name "ripgrep")
                       (list :name "magit")
                       (list :name "fd"))))
              ((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (anvil-pkg-pin-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (pkg-pin "ripgrep")
        (should (eq t (pkg-upgrade nil)))))
    (should (equal (append (list "profile" "upgrade" "magit" "fd")
                           (list "--profile" "/tmp/anvil-pkg-test-profile"))
                   captured-args))
    (should-not (member "ripgrep" captured-args))))

(ert-deftest anvil-pkg-pin-test-upgrade-all-with-only-pins-is-noop ()
  "pkg-upgrade nil returns t without shelling out when every package is pinned."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda ()
               (list (list :name "ripgrep")
                     (list :name "magit"))))
            ((symbol-function 'pkg-list-generations)
             (lambda ()
               (ert-fail "pkg-list-generations must not run for no-op upgrade")))
            ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
             (lambda ()
               (ert-fail "hook replay must not run for no-op upgrade"))))
    (anvil-pkg-pin-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-upgrade must not shell out when every package is pinned"))
      (pkg-pin "ripgrep")
      (pkg-pin "magit")
      (should (eq t (pkg-upgrade nil))))))

(ert-deftest anvil-pkg-pin-test-upgrade-pinned-name-signals-error ()
  "pkg-upgrade rejects direct upgrades of pinned packages."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-upgrade must not shell out for a pinned NAME"))
    (pkg-pin "ripgrep")
    (let ((err (should-error (pkg-upgrade 'ripgrep) :type 'anvil-pkg-error)))
      (should (string-match-p "pkg-upgrade: ripgrep is pinned; run pkg-unpin first"
                              (cadr err))))))

(ert-deftest anvil-pkg-pin-test-tool-wrapper-shapes ()
  "Pin MCP wrappers return the expected plist shapes."
  (anvil-pkg-pin-test--with-mock
      (lambda (_args)
        (ert-fail "pin MCP wrappers must not shell out to nix"))
    (should (equal '(:status "ok" :name "ripgrep")
                   (anvil-pkg--tool-pin "ripgrep")))
    (should (equal '(:count 1 :pins ("ripgrep"))
                   (anvil-pkg--tool-list-pins)))
    (should (equal '(:status "ok" :name "ripgrep")
                   (anvil-pkg--tool-unpin 'ripgrep)))
    (should (null (pkg-pinned-p "ripgrep")))))

(provide 'anvil-pkg-pin-test)
;;; anvil-pkg-pin-test.el ends here
