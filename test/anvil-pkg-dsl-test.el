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
      (should (eq 'stdenv (plist-get (plist-get ir :build-system) :type)))
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

(ert-deftest anvil-pkg-dsl-test-define-rejects-unknown-build-system ()
  "Unknown build-system symbol errors at parser."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system nim)))
   :type 'anvil-pkg-dsl-error))

;;;; --- renderer (pure, golden) ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-render-stdenv-url-fetch-golden ()
  "Renderer emits expected Nix derivation for stdenv + url-fetch + inputs."
  (let ((ir '(:name my-rg
              :version "13.0.0"
              :source (:type url-fetch
                       :url "https://example.com/rg-13.0.0.tar.gz"
                       :sha256 "sha256-xyz")
              :build-system (:type stdenv)
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

;;;; --- Phase 3: source types -----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-source-github-fetch ()
  "github-fetch sub-form parses owner / repo / rev / sha256."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-rg
             (version "13.0.0")
             (source (github-fetch :owner "BurntSushi" :repo "ripgrep"
                                   :rev "13.0.0"
                                   :sha256 "sha256-abc")))
          t)
    (let* ((ir (gethash 'my-rg anvil-pkg--registry))
           (src (plist-get ir :source)))
      (should (eq 'github-fetch (plist-get src :type)))
      (should (equal "BurntSushi" (plist-get src :owner)))
      (should (equal "ripgrep"     (plist-get src :repo)))
      (should (equal "13.0.0"      (plist-get src :rev)))
      (should (equal "sha256-abc"  (plist-get src :sha256))))))

(ert-deftest anvil-pkg-dsl-test-define-source-git-fetch ()
  "git-fetch sub-form parses url / rev / sha256."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-priv
             (version "0.1.0")
             (source (git-fetch :url "https://example.com/private.git"
                                :rev "abc1234"
                                :sha256 "sha256-priv")))
          t)
    (let* ((ir (gethash 'my-priv anvil-pkg--registry))
           (src (plist-get ir :source)))
      (should (eq 'git-fetch (plist-get src :type)))
      (should (equal "https://example.com/private.git"
                     (plist-get src :url)))
      (should (equal "abc1234"      (plist-get src :rev)))
      (should (equal "sha256-priv"  (plist-get src :sha256))))))

(ert-deftest anvil-pkg-dsl-test-render-github-fetch-golden ()
  "Renderer emits fetchFromGitHub for github-fetch source."
  (let ((ir '(:name my-rg
              :version "13.0.0"
              :source (:type github-fetch
                       :owner "BurntSushi"
                       :repo "ripgrep"
                       :rev "13.0.0"
                       :sha256 "sha256-abc")
              :build-system (:type stdenv)))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-rg\";\n"
                   "  version = \"13.0.0\";\n"
                   "  src = pkgs.fetchFromGitHub {\n"
                   "    owner = \"BurntSushi\";\n"
                   "    repo = \"ripgrep\";\n"
                   "    rev = \"13.0.0\";\n"
                   "    sha256 = \"sha256-abc\";\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-git-fetch-golden ()
  "Renderer emits fetchgit for git-fetch source."
  (let ((ir '(:name my-priv
              :version "0.1.0"
              :source (:type git-fetch
                       :url "https://example.com/repo.git"
                       :rev "abc1234"
                       :sha256 "sha256-priv")
              :build-system (:type stdenv)))
        (expected (concat
                   "pkgs.stdenv.mkDerivation {\n"
                   "  pname = \"my-priv\";\n"
                   "  version = \"0.1.0\";\n"
                   "  src = pkgs.fetchgit {\n"
                   "    url = \"https://example.com/repo.git\";\n"
                   "    rev = \"abc1234\";\n"
                   "    sha256 = \"sha256-priv\";\n"
                   "  };\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

;;;; --- Phase 3: build systems ----------------------------------------------

(ert-deftest anvil-pkg-dsl-test-define-build-system-rust-with-args ()
  "Rust build-system with :cargo-sha256 parses into IR."
  (anvil-pkg-dsl-test--with-clean-registry
    (eval '(pkg-define my-rust-tool
             (version "1.0.0")
             (source (url-fetch "https://x" :sha256 "sha256-src"))
             (build-system (rust :cargo-sha256 "sha256-cargo")))
          t)
    (let* ((ir (gethash 'my-rust-tool anvil-pkg--registry))
           (bs (plist-get ir :build-system)))
      (should (eq 'rust (plist-get bs :type)))
      (should (equal "sha256-cargo" (plist-get bs :cargo-sha256))))))

(ert-deftest anvil-pkg-dsl-test-rust-requires-cargo-sha256 ()
  "Rust build-system without :cargo-sha256 errors at parser."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (rust))))
   :type 'anvil-pkg-dsl-error))

(ert-deftest anvil-pkg-dsl-test-render-rust-golden ()
  "Renderer emits rustPlatform.buildRustPackage for rust build-system."
  (let ((ir '(:name my-rust-tool
              :version "1.0.0"
              :source (:type url-fetch
                       :url "https://example.com/rust-tool-1.0.tar.gz"
                       :sha256 "sha256-src")
              :build-system (:type rust :cargo-sha256 "sha256-cargo")
              :inputs (openssl)))
        (expected (concat
                   "pkgs.rustPlatform.buildRustPackage {\n"
                   "  pname = \"my-rust-tool\";\n"
                   "  version = \"1.0.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/rust-tool-1.0.tar.gz\";\n"
                   "    sha256 = \"sha256-src\";\n"
                   "  };\n"
                   "  buildInputs = with pkgs; [ openssl ];\n"
                   "  cargoSha256 = \"sha256-cargo\";\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-python-golden ()
  "Renderer emits buildPythonPackage for python build-system with :format."
  (let ((ir '(:name my-py-tool
              :version "0.5.0"
              :source (:type url-fetch
                       :url "https://example.com/my-py-tool-0.5.0.tar.gz"
                       :sha256 "sha256-py")
              :build-system (:type python :format "pyproject")))
        (expected (concat
                   "pkgs.python3Packages.buildPythonPackage {\n"
                   "  pname = \"my-py-tool\";\n"
                   "  version = \"0.5.0\";\n"
                   "  src = pkgs.fetchurl {\n"
                   "    url = \"https://example.com/my-py-tool-0.5.0.tar.gz\";\n"
                   "    sha256 = \"sha256-py\";\n"
                   "  };\n"
                   "  format = \"pyproject\";\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(ert-deftest anvil-pkg-dsl-test-render-go-golden ()
  "Renderer emits buildGoModule for go build-system, vendorHash null when absent."
  (let ((ir '(:name my-go-tool
              :version "0.3.0"
              :source (:type git-fetch
                       :url "https://example.com/my-go-tool.git"
                       :rev "v0.3.0"
                       :sha256 "sha256-go")
              :build-system (:type go)))
        (expected (concat
                   "pkgs.buildGoModule {\n"
                   "  pname = \"my-go-tool\";\n"
                   "  version = \"0.3.0\";\n"
                   "  src = pkgs.fetchgit {\n"
                   "    url = \"https://example.com/my-go-tool.git\";\n"
                   "    rev = \"v0.3.0\";\n"
                   "    sha256 = \"sha256-go\";\n"
                   "  };\n"
                   "  vendorHash = null;\n"
                   "}")))
    (should (equal expected (anvil-pkg-render-nix ir)))))

(provide 'anvil-pkg-dsl-test)
;;; anvil-pkg-dsl-test.el ends here
