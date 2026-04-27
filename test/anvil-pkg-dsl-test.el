;;; anvil-pkg-dsl-test.el --- ERT tests for anvil-pkg-dsl -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of anvil-pkg.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 2 ERT coverage.  Mocks `anvil-pkg--call-nix-fn' and
;; `anvil-pkg--write-flake-fn' so neither the nix binary nor disk
;; access is required to run the suite.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'anvil-pkg-dsl)

(defmacro anvil-pkg-dsl-test--with-clean-registry (&rest body)
  "Run BODY against an empty registry, restored on exit."
  (declare (indent 0))
  `(let ((anvil-pkg--registry (make-hash-table :test 'eq)))
     ,@body))

;;;; --- pkg-define / parser ---------------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-registers ()
  "pkg-define stores IR under the correct symbol with parsed source."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-tool
             (version "1.0.0")
             (source (url-fetch "https://example.com/tool-1.0.tar.gz"
                                :sha256 "sha256-abc")))
          t)
    (let ((ir (gethash 'my-tool anvil-pkg--registry)))
      (should ir)
      (should (eq 'my-tool (plist-get ir :name)))
      (should (equal "1.0.0" (plist-get ir :version)))
      (should (eq 'stdenv (plist-get ir :build-system)))
      (let ((src (plist-get ir :source)))
        (should (eq 'url-fetch (plist-get src :type)))
        (should (equal "https://example.com/tool-1.0.tar.gz"
                       (plist-get src :url)))
        (should (equal "sha256-abc" (plist-get src :sha256)))))))

(ert-deftest anvil-pkg-dsl-test-define-rejects-unknown-keyword ()
  "Unknown sub-form keyword raises at expansion time."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (typo-key "oops")))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-define-rejects-non-stdenv ()
  "Non-stdenv build-system errors at parser (Phase 2 limit)."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system rust-build-system)))
   :type 'anvil-pkg-dsl-error))

;;;; --- renderer (pure, golden) ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-render-stdenv-url-fetch-golden ()
  "Renderer emits expected Nix derivation for stdenv + url-fetch + inputs."
  (let ((ir '(:name my-rg
              :version "13.0.0"
              :source (:type url-fetch
                       :url "https://example.com/rg-13.0.0.tar.gz"
                       :sha256 "sha256-xyz")
              :build-system stdenv
              :inputs (pkg-config openssl)
              :native-inputs nil
              :install-phase "make install PREFIX=$out"))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-rg\";\n"
                   "  version = \"13.0.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/rg-13.0.0.tar.gz\";\n"
                   "    sha256 = \"sha256-xyz\";\n"
                   "  };\n"
                   "  buildInputs = with pkgs; [ pkg-config openssl ];\n"
                   "  installPhase = ''\n"
                   "    make install PREFIX=$out\n"
                   "  '';\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- pkg-install symbol path ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-install-symbol-dispatches ()
  "pkg-install with symbol arg writes flake + calls nix install."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-tool
             (version "1.0.0")
             (source (url-fetch "https://x" :sha256 "sha256-y")))
          t)
    (let* (call-nix-args
           write-called
           (anvil-pkg--call-nix-fn
            (lambda (args)
              (setq call-nix-args args)
              (list :exit 0 :stdout "" :stderr "")))
           (anvil-pkg--write-flake-fn
            (lambda ()
              (setq write-called t)
              "/tmp/anvil-pkg-test/flake.nix"))
           (anvil-pkg-profile-dir "/tmp/anvil-pkg-test/profile"))
      (should (eq t (pkg-install 'my-tool)))
      (should write-called)
      (should (member "install" call-nix-args))
      (should (cl-some (lambda (a)
                         (and (stringp a)
                              (string-match-p "path:.*#my-tool" a)))
                       call-nix-args)))))

(ert-deftest anvil-pkg-dsl-test-install-undefined-errors ()
  "pkg-install of an unregistered symbol signals undefined-package."
  (anvil-pkg-dsl-test--with-clean-registry
    (let ((anvil-pkg--call-nix-fn
           (lambda (_args) (list :exit 0 :stdout "" :stderr "")))
          (anvil-pkg--write-flake-fn
           (lambda () "/tmp/dummy.nix")))
      (should-error (pkg-install 'never-defined)
                    :type 'anvil-pkg-undefined-package))))

(provide 'anvil-pkg-dsl-test)
;;; anvil-pkg-dsl-test.el ends here
