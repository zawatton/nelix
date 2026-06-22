;;; nelix-core-info-test.el --- ERT tests for pkg-info -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton

;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 6-C coverage for `pkg-info' and its MCP wrapper.

;;; Code:

(require 'ert)
(require 'nelix-core)

(defmacro nelix-core-info-test--with-mock (mock-fn &rest body)
  "Run BODY with `nelix-core--call-nix-fn' bound to MOCK-FN."
  (declare (indent 1))
  `(let ((nelix-core--call-nix-fn ,mock-fn)
         (nelix-core-nix-channel "nixpkgs")
         (nelix-core-profile-dir "/tmp/nelix-core-test-profile"))
     ,@body))

(ert-deftest nelix-core-info-test-installed-merges-search-metadata ()
  "pkg-info returns installed t and merges in search metadata."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (should (member "profile" args))
          (should (member "--json" args))
          (should (member "--profile" args))
          (list :exit 0
                :stdout (concat
                         "{\"version\":3,"
                         "\"elements\":{"
                         "\"ripgrep\":{"
                         "\"attrPath\":\"legacyPackages.x86_64-linux.ripgrep\","
                         "\"originalUrl\":\"flake:nixpkgs\","
                         "\"storePaths\":[\"/nix/store/abc-ripgrep-14.1.1\"]"
                         "}"
                         "}}")
                :stderr ""))
         ((member "search" args)
          (should (member "ripgrep" args))
          (list :exit 0
                :stdout (concat
                         "{"
                         "\"legacyPackages.x86_64-linux.ripgrep\":"
                         "{\"pname\":\"ripgrep\","
                         "\"version\":\"14.1.1\","
                         "\"description\":\"Fast grep\"}"
                         "}")
                :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((info (pkg-info "ripgrep")))
      (should (equal "ripgrep" (plist-get info :name)))
      (should (eq t (plist-get info :installed)))
      (should (equal "14.1.1" (plist-get info :version)))
      (should (equal "Fast grep" (plist-get info :description)))
      (should (equal "legacyPackages.x86_64-linux.ripgrep"
                     (plist-get info :attr-path)))
      (should (equal "flake:nixpkgs" (plist-get info :original-url)))
      (should (equal '("/nix/store/abc-ripgrep-14.1.1")
                     (plist-get info :store-paths))))))

(ert-deftest nelix-core-info-test-installed-survives-search-failure ()
  "pkg-info still returns installed data when `pkg-search' fails."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (list :exit 0
                :stdout (concat
                         "{\"version\":3,"
                         "\"elements\":{"
                         "\"ripgrep\":{"
                         "\"attrPath\":\"ripgrep\","
                         "\"originalUrl\":\"flake:nixpkgs\","
                         "\"storePaths\":[\"/nix/store/abc-ripgrep-14.1.1\"]"
                         "}"
                         "}}")
                :stderr ""))
         ((member "search" args)
          (list :exit 1 :stdout "" :stderr "search backend failed\n"))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((info (pkg-info "ripgrep")))
      (should (eq t (plist-get info :installed)))
      (should (null (plist-get info :version)))
      (should (null (plist-get info :description)))
      (should (equal "ripgrep" (plist-get info :attr-path)))
      (should (equal "flake:nixpkgs" (plist-get info :original-url)))
      (should (equal '("/nix/store/abc-ripgrep-14.1.1")
                     (plist-get info :store-paths))))))

(ert-deftest nelix-core-info-test-searchable-not-installed ()
  "pkg-info returns search metadata when the package is not installed."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (list :exit 0
                :stdout "{\"version\":3,\"elements\":{}}"
                :stderr ""))
         ((member "search" args)
          (should (member "rg" args))
          (list :exit 0
                :stdout (concat
                         "{"
                         "\"legacyPackages.x86_64-linux.ripgrep\":"
                         "{\"pname\":\"ripgrep\","
                         "\"version\":\"14.1.1\","
                         "\"description\":\"Fast grep\"},"
                         "\"legacyPackages.x86_64-linux.rg\":"
                         "{\"pname\":\"rg\","
                         "\"version\":\"0.1.0\","
                         "\"description\":\"rg shim\"}"
                         "}")
                :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((info (pkg-info "rg")))
      (should (equal "rg" (plist-get info :name)))
      (should (null (plist-get info :installed)))
      (should (equal "0.1.0" (plist-get info :version)))
      (should (equal "rg shim" (plist-get info :description)))
      (should (equal "legacyPackages.x86_64-linux.rg"
                     (plist-get info :attr-path)))
      (should (null (plist-get info :original-url)))
      (should (null (plist-get info :store-paths))))))

(ert-deftest nelix-core-info-test-missing-package-returns-nil ()
  "pkg-info returns nil when neither list nor search finds NAME."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (list :exit 0
                :stdout "{\"version\":3,\"elements\":{}}"
                :stderr ""))
         ((member "search" args)
          (list :exit 0 :stdout "{}" :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (should (null (pkg-info "does-not-exist")))))

(ert-deftest nelix-core-info-test-symbol-coercion-works ()
  "pkg-info accepts a symbol NAME and coerces it to a string."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (list :exit 0
                :stdout "{\"version\":3,\"elements\":{}}"
                :stderr ""))
         ((member "search" args)
          (should (member "ripgrep" args))
          (list :exit 0
                :stdout (concat
                         "{"
                         "\"legacyPackages.x86_64-linux.ripgrep\":"
                         "{\"pname\":\"ripgrep\","
                         "\"version\":\"14.1.1\","
                         "\"description\":\"Fast grep\"}"
                         "}")
                :stderr ""))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((info (pkg-info 'ripgrep)))
      (should (equal "ripgrep" (plist-get info :name)))
      (should (equal "14.1.1" (plist-get info :version))))))

(ert-deftest nelix-core-info-test-bad-arguments-signal-error ()
  "pkg-info signals `nelix-error' for invalid NAME values."
  (nelix-core-info-test--with-mock
      (lambda (_args)
        (ert-fail "mock backend should not be called"))
    (let ((err (should-error (pkg-info 42) :type 'nelix-error)))
      (should (string-match-p "pkg-info: NAME must be string or symbol"
                              (cadr err))))))

(ert-deftest nelix-core-info-test-tool-wrapper-found-shape ()
  "The MCP wrapper adds :found for both hit and miss results."
  (nelix-core-info-test--with-mock
      (lambda (args)
        (cond
         ((member "list" args)
          (list :exit 0
                :stdout "{\"version\":3,\"elements\":{}}"
                :stderr ""))
         ((member "search" args)
          (cond
           ((member "found-pkg" args)
            (list :exit 0
                  :stdout (concat
                           "{"
                           "\"legacyPackages.x86_64-linux.found-pkg\":"
                           "{\"pname\":\"found-pkg\","
                           "\"version\":\"1.0.0\","
                           "\"description\":\"Found package\"}"
                           "}")
                  :stderr ""))
           ((member "missing-pkg" args)
            (list :exit 0 :stdout "{}" :stderr ""))
           (t (ert-fail (format "unexpected search args: %S" args)))))
         (t (ert-fail (format "unexpected nix args: %S" args)))))
    (let ((found (nelix-core--tool-info "found-pkg"))
          (missing (nelix-core--tool-info 'missing-pkg)))
      (should (eq t (plist-get found :found)))
      (should (equal "found-pkg" (plist-get found :name)))
      (should (equal "1.0.0" (plist-get found :version)))
      (should (null (plist-get found :installed)))
      (should (null (plist-get missing :found)))
      (should (equal "missing-pkg" (plist-get missing :name))))))

(provide 'nelix-core-info-test)
;;; nelix-core-info-test.el ends here
