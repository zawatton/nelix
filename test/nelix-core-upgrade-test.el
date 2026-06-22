;;; nelix-core-upgrade-test.el --- ERT tests for pkg-upgrade -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Focused ERT coverage for Phase 6-B `pkg-upgrade'.  All tests mock
;; `nelix-core--call-nix-fn' so no nix binary is required to run them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-state)

(defmacro nelix-core-upgrade-test--with-mock (mock-fn &rest body)
  "Run BODY with `nelix-core--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `nelix-core--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default).

The state file is bound to a tmp path so the real
~/.local/state/nelix/state.json is never touched and the
in-process state cache is reset between tests."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "nelix-core-upgrade-test-" nil ".json"))
          (nelix-state-file tmp)
          (nelix-state--cache 'unloaded)
          (nelix-state--loaded-from nil)
          (nelix-core--call-nix-fn ,mock-fn)
          (nelix-core-nix-channel "nixpkgs")
          (nelix-core-profile-dir "/tmp/nelix-core-test-profile"))
     (unwind-protect
         (progn
           (delete-file tmp)
           (nelix-state-put nelix-core--nix-version-namespace
                                nelix-core--nix-version-key
                                "2.18.0")
           ,@body)
       (when (file-exists-p tmp) (delete-file tmp)))))

(ert-deftest nelix-core-upgrade-test-upgrade-all-happy ()
  "pkg-upgrade nil uses the portable \".*\" matcher."
  (let ((captured-args nil)
        (calls nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda ()
                 (push 'refresh calls)
                 nil))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda ()
                 (push 'hooks calls))))
      (nelix-core-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade nil)))))
    (should (equal (append (list "profile" "upgrade" ".*")
                           (list "--profile" "/tmp/nelix-core-test-profile"))
                   captured-args))
    (should (equal '(refresh hooks) (nreverse calls)))))

(ert-deftest nelix-core-upgrade-test-upgrade-one-happy ()
  "pkg-upgrade forwards a single string NAME as the matcher."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (nelix-core-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade "ripgrep")))))
    (should (equal (append (list "profile" "upgrade" "ripgrep")
                           (list "--profile" "/tmp/nelix-core-test-profile"))
                   captured-args))))

(ert-deftest nelix-core-upgrade-test-symbol-coercion ()
  "pkg-upgrade coerces symbol NAME to a string matcher."
  (let ((captured-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations) (lambda () nil))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda () nil)))
      (nelix-core-upgrade-test--with-mock
          (lambda (args)
            (setq captured-args args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade 'magit)))))
    (should (equal (append (list "profile" "upgrade" "magit")
                           (list "--profile" "/tmp/nelix-core-test-profile"))
                   captured-args))))

(ert-deftest nelix-core-upgrade-test-nix-error ()
  "pkg-upgrade signals `nelix-nix-failed' on non-zero exit."
  (cl-letf (((symbol-function 'pkg-list-generations)
             (lambda ()
               (ert-fail "pkg-list-generations must not run on nix failure")))
            ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
             (lambda ()
               (ert-fail "hook replay must not run on nix failure"))))
    (nelix-core-upgrade-test--with-mock
        (lambda (_args)
          (list :exit 1
                :stdout ""
                :stderr "error: upgrade failed\n"))
      (let ((err (should-error (pkg-upgrade "ripgrep")
                               :type 'nelix-nix-failed)))
        (should (string-match-p "nix profile upgrade ripgrep failed" (cadr err)))
        (should (string-match-p "upgrade failed" (cadr err)))))))

(ert-deftest nelix-core-upgrade-test-bad-type ()
  "pkg-upgrade rejects NAME values that are not string, symbol, or nil."
  (nelix-core-upgrade-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-upgrade must not shell out for invalid NAME types"))
    (let ((err (should-error (pkg-upgrade 42)
                             :type 'nelix-error)))
      (should (string-match-p "pkg-upgrade: NAME must be string, symbol, or nil"
                              (cadr err))))))

(ert-deftest nelix-core-upgrade-test-empty-string-rejects ()
  "pkg-upgrade rejects blank string NAME at the public API."
  (nelix-core-upgrade-test--with-mock
      (lambda (_args)
        (ert-fail "pkg-upgrade must not shell out for blank NAME"))
    (let ((err (should-error (pkg-upgrade "  ")
                             :type 'nelix-error)))
      (should (string-match-p "pkg-upgrade: NAME must be non-empty string or symbol"
                              (cadr err))))))

(ert-deftest nelix-core-upgrade-test-tool-empty-string-upgrades-all ()
  "The MCP tool maps blank NAME to upgrade-all."
  (let (captured-name)
    (cl-letf (((symbol-function 'pkg-upgrade)
               (lambda (&optional name)
                 (setq captured-name name)
                 t)))
      (should (equal '(:status "ok" :name :all)
                     (nelix-core--tool-upgrade "   "))))
    (should (null captured-name))))

(ert-deftest nelix-core-upgrade-test-tool-bad-type ()
  "The MCP tool rejects unsupported NAME types."
  (cl-letf (((symbol-function 'pkg-upgrade)
             (lambda (&optional _name)
               (ert-fail "tool must reject bad NAME before pkg-upgrade"))))
    (let ((err (should-error (nelix-core--tool-upgrade 42)
                             :type 'nelix-error)))
      (should (string-match-p "pkg-upgrade: NAME must be string, symbol, or nil"
                              (cadr err))))))

(ert-deftest nelix-core-upgrade-test-plan-all-separates-pinned ()
  "pkg-upgrade-plan reports concrete bulk targets without mutating the profile."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda ()
               (list (list :name "ripgrep" :attr-path "legacyPackages.x86_64-linux.ripgrep")
                     (list :name "fd" :attr-path "legacyPackages.x86_64-linux.fd")
                     (list :name "magit" :attr-path "packages.x86_64-linux.magit"))))
            ((symbol-function 'pkg-list-generations)
             (lambda ()
               (ert-fail "pkg-upgrade-plan must not refresh generations")))
            ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
             (lambda ()
               (ert-fail "pkg-upgrade-plan must not replay hooks"))))
    (nelix-core-upgrade-test--with-mock
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

(ert-deftest nelix-core-upgrade-test-plan-direct-pinned-is-blocked ()
  "pkg-upgrade-plan reports a pinned direct target instead of upgrading it."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda ()
               (list (list :name "ripgrep" :attr-path "legacyPackages.x86_64-linux.ripgrep")))))
    (nelix-core-upgrade-test--with-mock
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

(ert-deftest nelix-core-upgrade-test-plan-direct-missing-is-blocked ()
  "pkg-upgrade-plan reports missing direct targets read-only."
  (cl-letf (((symbol-function 'pkg-list)
             (lambda () nil)))
    (nelix-core-upgrade-test--with-mock
        (lambda (_args)
          (ert-fail "pkg-upgrade-plan must not shell out when pkg-list is mocked"))
      (let ((plan (pkg-upgrade-plan "ripgrep")))
        (should (equal "ripgrep" (plist-get plan :name)))
        (should (eq :missing (plist-get plan :blocked)))
        (should (equal "ripgrep" (plist-get plan :missing)))
        (should (= 0 (plist-get plan :count)))
        (should (plist-get plan :empty))))))

(ert-deftest nelix-core-upgrade-test-tool-plan-empty-name-means-all ()
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
                   (nelix-core--tool-upgrade-plan "   ")))))

(ert-deftest nelix-core-upgrade-test-refresh-error-still-replays-hooks ()
  "pkg-upgrade ignores refresh errors and still replays emacs hooks."
  (let ((calls nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda ()
                 (push 'refresh calls)
                 (signal 'nelix-error '("refresh failed"))))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda ()
                 (push 'hooks calls))))
      (nelix-core-upgrade-test--with-mock
          (lambda (_args)
            (list :exit 0 :stdout "" :stderr ""))
        (should (eq t (pkg-upgrade "ripgrep")))))
    (should (equal '(refresh hooks) (nreverse calls)))))

;;; nelix-core-upgrade-test.el ends here
