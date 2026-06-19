;;; anvil-pkg-upgrade-test.el --- ERT tests for pkg-upgrade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Focused ERT coverage for Phase 6-B `pkg-upgrade'.  All tests mock
;; `anvil-pkg--call-nix-fn' so no nix binary is required to run them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg)
(require 'anvil-pkg-state)

(defmacro anvil-pkg-upgrade-test--with-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `anvil-pkg--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default).

The state file is bound to a tmp path so the real
~/.local/state/nelix/state.json is never touched and the
in-process state cache is reset between tests."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "anvil-pkg-upgrade-test-" nil ".json"))
          (anvil-pkg-state-file tmp)
          (anvil-pkg-state--cache 'unloaded)
          (anvil-pkg-state--loaded-from nil)
          (anvil-pkg--call-nix-fn ,mock-fn)
          (anvil-pkg-nix-channel "nixpkgs")
          (anvil-pkg-profile-dir "/tmp/anvil-pkg-test-profile"))
     (unwind-protect
         (progn
           (delete-file tmp)
           (anvil-pkg-state-put anvil-pkg--nix-version-namespace
                                anvil-pkg--nix-version-key
                                "2.18.0")
           ,@body)
       (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest anvil-pkg-upgrade-test-upgrade-all-happy ()
  "pkg-upgrade nil uses the portable \".*\" matcher."
  (let ((captured-args nil)
        (calls nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda ()
                 (push 'refresh calls)
                 nil))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda ()
                 (push 'hooks calls))))
      (anvil-pkg-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade nil)))))
    (should (equal (append (list "profile" "upgrade" ".*")
                           (list "--profile" "/tmp/anvil-pkg-test-profile"))
                   captured-args))
    (should (equal '(refresh hooks) (nreverse calls)))))

(ert-deftest anvil-pkg-upgrade-test-upgrade-one-happy ()
  "pkg-upgrade forwards a single string NAME as the matcher."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (anvil-pkg-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade "ripgrep")))))
    (should (equal (append (list "profile" "upgrade" "ripgrep")
                           (list "--profile" "/tmp/anvil-pkg-test-profile"))
                   captured-args))))

(ert-deftest anvil-pkg-upgrade-test-symbol-coercion ()
  "pkg-upgrade coerces symbol NAME to a string matcher."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (anvil-pkg-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade 'magit)))))
    (should (equal (append (list "profile" "upgrade" "magit")
                           (list "--profile" "/tmp/anvil-pkg-test-profile"))
                   captured-args))))

(ert-deftest anvil-pkg-upgrade-test-nix-error ()
  "pkg-upgrade signals `anvil-pkg-nix-failed' on non-zero exit."
  (cl-letf (((symbol-function 'pkg-list-generations)
             (lambda ()
               (ert-fail "pkg-list-generations must not run on nix failure")))
            ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
             (lambda ()
               (ert-fail "hook replay must not run on nix failure"))))
    (anvil-pkg-upgrade-test--with-mock
        (lambda (_args)
          (list :exit 1
                :stdout ""
                :stderr "error: upgrade failed\n"))
      (let ((err (should-error (pkg-upgrade "ripgrep")
                               :type 'anvil-pkg-nix-failed)))
        (should (string-match-p "nix profile upgrade ripgrep failed" (cadr err)))
        (should (string-match-p "upgrade failed" (cadr err)))))))

(ert-deftest anvil-pkg-upgrade-test-bad-type ()
  "pkg-upgrade rejects NAME values that are not string, symbol, or nil."
  (anvil-pkg-upgrade-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-upgrade must not shell out for invalid NAME types"))
    (let ((err (should-error (pkg-upgrade 42)
                             :type 'anvil-pkg-error)))
      (should (string-match-p "pkg-upgrade: NAME must be string, symbol, or nil"
                              (cadr err))))))

(ert-deftest anvil-pkg-upgrade-test-empty-string-rejects ()
  "pkg-upgrade rejects blank string NAME at the public API."
  (anvil-pkg-upgrade-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-upgrade must not shell out for blank NAME"))
    (let ((err (should-error (pkg-upgrade "  ")
                             :type 'anvil-pkg-error)))
      (should (string-match-p "pkg-upgrade: NAME must be non-empty string or symbol"
                              (cadr err))))))

(ert-deftest anvil-pkg-upgrade-test-tool-empty-string-upgrades-all ()
  "The MCP tool maps blank NAME to upgrade-all."
  (let (captured-name)
    (cl-letf (((symbol-function 'pkg-upgrade)
               (lambda (&optional name)
                 (setq captured-name name)
                 t)))
      (should (equal '(:status "ok" :name :all)
                     (anvil-pkg--tool-upgrade "   "))))
    (should (null captured-name))))

(ert-deftest anvil-pkg-upgrade-test-tool-bad-type ()
  "The MCP tool rejects unsupported NAME types."
  (cl-letf (((symbol-function 'pkg-upgrade)
             (lambda (&optional _name)
               (ert-fail "tool must reject bad NAME before pkg-upgrade"))))
    (let ((err (should-error (anvil-pkg--tool-upgrade 42)
                             :type 'anvil-pkg-error)))
      (should (string-match-p "pkg-upgrade: NAME must be string, symbol, or nil"
                              (cadr err))))))

(ert-deftest anvil-pkg-upgrade-test-plan-all-separates-pinned ()
  "pkg-upgrade-plan reports concrete bulk targets without mutating the profile."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda ()
               (list (list :name "ripgrep" :attr-path "legacyPackages.x86_64-linux.ripgrep")
                     (list :name "fd" :attr-path "legacyPackages.x86_64-linux.fd")
                     (list :name "magit" :attr-path "packages.x86_64-linux.magit"))))
            ((symbol-function 'pkg-list-generations)
             (lambda ()
               (ert-fail "pkg-upgrade-plan must not refresh generations")))
            ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
             (lambda ()
               (ert-fail "pkg-upgrade-plan must not replay hooks"))))
    (anvil-pkg-upgrade-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-upgrade-plan must not call nix when pkg-list is mocked"))
      (pkg-pin "ripgrep")
      (let ((plan (pkg-upgrade-plan)))
        (should (eq 'upgrade (plist-get plan :operation)))
        (should (eq :all (plist-get plan :name)))
        (should (= 2 (plist-get plan :count)))
        (should (equal '("fd" "magit")
                       (mapcar (lambda (row) (plist-get row :name))
                               (plist-get plan :upgrade))))
        (should (equal '("ripgrep")
                       (mapcar (lambda (row) (plist-get row :name))
                               (plist-get plan :pinned))))
        (should-not (plist-get plan :blocked))
        (should-not (plist-get plan :empty))))))

(ert-deftest anvil-pkg-upgrade-test-plan-direct-pinned-is-blocked ()
  "pkg-upgrade-plan reports a pinned direct target instead of upgrading it."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda ()
               (list (list :name "ripgrep" :attr-path "legacyPackages.x86_64-linux.ripgrep")))))
    (anvil-pkg-upgrade-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-upgrade-plan must not shell out when pkg-list is mocked"))
      (pkg-pin "ripgrep")
      (let ((plan (pkg-upgrade-plan 'ripgrep)))
        (should (equal "ripgrep" (plist-get plan :name)))
        (should (eq :pinned (plist-get plan :blocked)))
        (should (= 0 (plist-get plan :count)))
        (should (plist-get plan :empty))
        (should (equal '("ripgrep")
                       (mapcar (lambda (row) (plist-get row :name))
                               (plist-get plan :pinned))))))))

(ert-deftest anvil-pkg-upgrade-test-plan-direct-missing-is-blocked ()
  "pkg-upgrade-plan reports missing direct targets read-only."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda () nil)))
    (anvil-pkg-upgrade-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-upgrade-plan must not shell out when pkg-list is mocked"))
      (let ((plan (pkg-upgrade-plan "ripgrep")))
        (should (equal "ripgrep" (plist-get plan :name)))
        (should (eq :missing (plist-get plan :blocked)))
        (should (equal "ripgrep" (plist-get plan :missing)))
        (should (= 0 (plist-get plan :count)))
        (should (plist-get plan :empty))))))

(ert-deftest anvil-pkg-upgrade-test-tool-plan-empty-name-means-all ()
  "The MCP plan wrapper maps blank NAME to a read-only all-package plan."
  (cl-letf (((symbol-function 'pkg-upgrade-plan)
             (lambda (&optional name)
               (should (null name))
               (list :operation 'upgrade
                     :name :all
                     :count 0
                     :upgrade nil
                     :pinned nil
                     :blocked nil
                     :empty t))))
    (should (equal '(:operation upgrade
                     :name :all
                     :count 0
                     :upgrade nil
                     :pinned nil
                     :blocked nil
                     :empty t
                     :status "ok")
                   (anvil-pkg--tool-upgrade-plan "   ")))))

(ert-deftest anvil-pkg-upgrade-test-refresh-error-still-replays-hooks ()
  "pkg-upgrade ignores refresh errors and still replays emacs hooks."
  (let ((calls nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda ()
                 (push 'refresh calls)
                 (signal 'anvil-pkg-error '("refresh failed"))))
              ((symbol-function 'anvil-pkg--rollback-replay-emacs-hooks)
               (lambda ()
                 (push 'hooks calls))))
      (anvil-pkg-upgrade-test--with-mock
          (lambda (_args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade "ripgrep")))))
    (should (equal '(refresh hooks) (nreverse calls)))))

;;; anvil-pkg-upgrade-test.el ends here
