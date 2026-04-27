;;; anvil-pkg-test.el --- ERT tests for anvil-pkg -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 1 ERT coverage for the public API.  All tests mock
;; `anvil-pkg--call-nix-fn' so no nix binary is required to run them.
;;
;; Run with:
;;   make test
;; or directly:
;;   emacs -Q --batch -L . -L test -l ert -l test/anvil-pkg-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg)

(defmacro anvil-pkg-test--with-mock (mock-fn &rest body)
  "Run BODY with `anvil-pkg--call-nix-fn' bound to MOCK-FN.

The mock is also relied on by `anvil-pkg--ensure-nix' to skip the
real `executable-find' check (the ensure helper exempts test mode
when the call-nix fn is not the default)."
  (declare (indent 1))
  `(let ((anvil-pkg--call-nix-fn ,mock-fn)
         (anvil-pkg-nix-channel "nixpkgs")
         (anvil-pkg-profile-dir "/tmp/anvil-pkg-test-profile"))
     ,@body))

;;;; --- install ---------------------------------------------------------------

(ert-deftest anvil-pkg-test-install-happy ()
  "anvil-pkg-install returns t and forwards correct args on nix exit 0."
  (let (captured-args)
    (anvil-pkg-test--with-mock
        (lambda (args)
          (setq captured-args args)
          (list :exit 0 :stdout "" :stderr ""))
      (should (eq t (pkg-install "ripgrep"))))
    (should (member "profile" captured-args))
    (should (member "install" captured-args))
    (should (member "nixpkgs#ripgrep" captured-args))
    (should (member "--profile" captured-args))))

(ert-deftest anvil-pkg-test-install-error ()
  "anvil-pkg-install signals anvil-pkg-nix-failed on non-zero exit, with stderr."
  (anvil-pkg-test--with-mock
      (lambda (_args)
        (list :exit 1
              :stdout ""
              :stderr "error: cannot resolve flake reference 'nixpkgs#nope'\n"))
    (let ((err (should-error (pkg-install "nope")
                             :type 'anvil-pkg-nix-failed)))
      (should (string-match-p "cannot resolve" (cadr err))))))

;;;; --- search ----------------------------------------------------------------

(ert-deftest anvil-pkg-test-search-happy ()
  "anvil-pkg-search parses JSON into plists with :name / :version / :description."
  (anvil-pkg-test--with-mock
      (lambda (args)
        (should (member "search" args))
        (should (member "ripgrep" args))
        (should (member "--json" args))
        (list :exit 0
              :stdout (concat
                       "{"
                       "\"legacyPackages.x86_64-linux.ripgrep\":"
                       "{\"pname\":\"ripgrep\","
                       "\"version\":\"13.0.0\","
                       "\"description\":\"A line-oriented search tool\"}"
                       "}")
              :stderr ""))
    (let* ((res (pkg-search "ripgrep"))
           (row (car res)))
      (should (= 1 (length res)))
      (should (equal "ripgrep" (plist-get row :name)))
      (should (equal "13.0.0" (plist-get row :version)))
      (should (equal "A line-oriented search tool"
                     (plist-get row :description)))
      (should (string-match-p "ripgrep$" (plist-get row :attrpath))))))

(ert-deftest anvil-pkg-test-search-empty ()
  "anvil-pkg-search returns nil when nix returns an empty object."
  (anvil-pkg-test--with-mock
      (lambda (_args) (list :exit 0 :stdout "{}" :stderr ""))
    (should (null (pkg-search "no-such-pkg-xyzzy")))))

;;;; --- list ------------------------------------------------------------------

(ert-deftest anvil-pkg-test-list-happy ()
  "anvil-pkg-list parses Nix 2.18 modern profile JSON."
  (anvil-pkg-test--with-mock
      (lambda (args)
        (should (member "profile" args))
        (should (member "list" args))
        (should (member "--json" args))
        (should (member "--profile" args))
        (list :exit 0
              :stdout (concat
                       "{\"version\":3,"
                       "\"elements\":{"
                       "\"ripgrep\":{"
                       "\"active\":true,"
                       "\"attrPath\":\"ripgrep\","
                       "\"originalUrl\":\"flake:nixpkgs\","
                       "\"storePaths\":[\"/nix/store/abc-ripgrep-13.0.0\"]"
                       "}"
                       "}}")
              :stderr ""))
    (let* ((res (pkg-list))
           (row (car res)))
      (should (= 1 (length res)))
      (should (equal "ripgrep" (plist-get row :name)))
      (should (equal "ripgrep" (plist-get row :attr-path)))
      (should (equal "flake:nixpkgs" (plist-get row :original-url)))
      (should (member "/nix/store/abc-ripgrep-13.0.0"
                      (plist-get row :store-paths))))))

(ert-deftest anvil-pkg-test-list-empty ()
  "anvil-pkg-list returns nil for a fresh, empty profile."
  (anvil-pkg-test--with-mock
      (lambda (_args)
        (list :exit 0
              :stdout "{\"version\":3,\"elements\":{}}"
              :stderr ""))
    (should (null (pkg-list)))))

(provide 'anvil-pkg-test)
;;; anvil-pkg-test.el ends here
