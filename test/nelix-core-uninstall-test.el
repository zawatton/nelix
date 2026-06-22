;;; nelix-core-uninstall-test.el --- ERT tests for pkg-uninstall -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 6-A ERT coverage for `pkg-uninstall'.  All tests mock
;; `nelix-core--call-nix-fn' so no nix binary is required to run them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'nelix-core)
(require 'nelix-state)

(defmacro nelix-core-uninstall-test--with-mock (mock-fn &rest body)
  "Run BODY with `nelix-core--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `nelix-core--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default).

Pre-seeds the persistent state with a sentinel pre-2.34 Nix
version so uninstall-path tests that do not care about a
`nix --version' probe do not need to mock it.

The state file is bound to a tmp path so the real
~/.local/state/nelix/state.json is never touched and the
in-process state cache is reset between tests."
  (declare (indent 1))
  `(let* ((tmp (make-temp-file "nelix-core-uninstall-test-" nil ".json"))
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

(ert-deftest nelix-core-uninstall-test-happy ()
  "pkg-uninstall returns t and forwards correct remove args on nix exit 0."
  (let ((remove-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda () 'ignored))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda () 'ignored)))
      (nelix-core-uninstall-test--with-mock
          (lambda (args)
            (cond
             ((and (member "profile" args)
                   (member "list" args)
                   (member "--json" args))
              (list :exit 0
                    :stdout (concat
                             "{\"version\":3,\"elements\":{"
                             "\"ripgrep\":{"
                             "\"active\":true,"
                             "\"attrPath\":\"ripgrep\","
                             "\"originalUrl\":\"flake:nixpkgs\","
                             "\"storePaths\":[\"/nix/store/abc-ripgrep\"]"
                             "}}}")
                    :stderr ""))
             ((and (member "profile" args)
                   (member "remove" args))
              (setq remove-args args)
              (list :exit 0 :stdout "" :stderr ""))
             (t (ert-fail (format "unexpected nix args: %S" args)))))
        (should (eq t (pkg-uninstall "ripgrep")))))
    (should (equal '("profile" "remove" "ripgrep"
                     "--profile" "/tmp/nelix-core-test-profile")
                   remove-args))))

(ert-deftest nelix-core-uninstall-test-not-installed ()
  "pkg-uninstall signals `nelix-error' when NAME is absent from the profile."
  (nelix-core-uninstall-test--with-mock
      (lambda (args)
        (cond
         ((and (member "profile" args)
               (member "list" args)
               (member "--json" args))
          (list :exit 0
                :stdout "{\"version\":3,\"elements\":{}}"
                :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((err (should-error (pkg-uninstall "ripgrep")
                             :type 'nelix-error)))
      (should (string-match-p "not installed in the nelix-core profile"
                              (cadr err))))))

(ert-deftest nelix-core-uninstall-test-remove-error ()
  "pkg-uninstall signals `nelix-nix-failed' on non-zero remove exit."
  (nelix-core-uninstall-test--with-mock
      (lambda (args)
        (cond
         ((and (member "profile" args)
               (member "list" args)
               (member "--json" args))
          (list :exit 0
                :stdout (concat
                         "{\"version\":3,\"elements\":{"
                         "\"ripgrep\":{"
                         "\"active\":true,"
                         "\"attrPath\":\"ripgrep\","
                         "\"originalUrl\":\"flake:nixpkgs\","
                         "\"storePaths\":[\"/nix/store/abc-ripgrep\"]"
                         "}}}")
                :stderr ""))
         ((and (member "profile" args)
               (member "remove" args))
          (list :exit 1
                :stdout ""
                :stderr "error: no such installed package\n"))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((err (should-error (pkg-uninstall "ripgrep")
                             :type 'nelix-nix-failed)))
      (should (string-match-p "no such installed package" (cadr err))))))

(ert-deftest nelix-core-uninstall-test-symbol-name-coercion ()
  "pkg-uninstall coerces symbol NAME via `symbol-name' before removal."
  (let ((remove-args nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda () 'ignored))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda () 'ignored)))
      (nelix-core-uninstall-test--with-mock
          (lambda (args)
            (cond
             ((and (member "profile" args)
                   (member "list" args)
                   (member "--json" args))
              (list :exit 0
                    :stdout (concat
                             "{\"version\":3,\"elements\":{"
                             "\"ripgrep\":{"
                             "\"active\":true,"
                             "\"attrPath\":\"ripgrep\","
                             "\"originalUrl\":\"flake:nixpkgs\","
                             "\"storePaths\":[\"/nix/store/abc-ripgrep\"]"
                             "}}}")
                    :stderr ""))
             ((and (member "profile" args)
                   (member "remove" args))
              (setq remove-args args)
              (list :exit 0 :stdout "" :stderr ""))
             (t (ert-fail (format "unexpected nix args: %S" args)))))
        (should (eq t (pkg-uninstall 'ripgrep)))))
    (should (equal "ripgrep" (nth 2 remove-args)))))

(ert-deftest nelix-core-uninstall-test-refreshes-generations-and-replays-hooks ()
  "pkg-uninstall refreshes the generations mirror and replays hooks after remove."
  (let ((calls nil))
    (cl-letf (((symbol-function 'pkg-list-generations)
               (lambda ()
                 (push 'refresh calls)
                 (signal 'nelix-error '("ignore refresh failure"))))
              ((symbol-function 'nelix-core--rollback-replay-emacs-hooks)
               (lambda ()
                 (push 'replay calls))))
      (nelix-core-uninstall-test--with-mock
          (lambda (args)
            (cond
             ((and (member "profile" args)
                   (member "list" args)
                   (member "--json" args))
              (list :exit 0
                    :stdout (concat
                             "{\"version\":3,\"elements\":{"
                             "\"ripgrep\":{"
                             "\"active\":true,"
                             "\"attrPath\":\"ripgrep\","
                             "\"originalUrl\":\"flake:nixpkgs\","
                             "\"storePaths\":[\"/nix/store/abc-ripgrep\"]"
                             "}}}")
                    :stderr ""))
             ((and (member "profile" args)
                   (member "remove" args))
              (list :exit 0 :stdout "" :stderr ""))
             (t (ert-fail (format "unexpected nix args: %S" args)))))
        (should (eq t (pkg-uninstall "ripgrep")))))
    (should (equal '(refresh replay) (nreverse calls)))))

(ert-deftest nelix-core-uninstall-test-bad-name-type ()
  "pkg-uninstall signals `nelix-error' for an invalid NAME type."
  (nelix-core-uninstall-test--with-mock
      (lambda (args)
        (ert-fail (format "unexpected nix args: %S" args)))
    (let ((err (should-error (pkg-uninstall 42)
                             :type 'nelix-error)))
      (should (string-match-p "NAME must be string or symbol" (cadr err))))))

(provide 'nelix-core-uninstall-test)
;;; nelix-core-uninstall-test.el ends here
