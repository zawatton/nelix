;;; nelix-core-buildsys-test.el --- ERT tests for new DSL build systems -*- lexical-binding: t; -*-

;; Copyright (C) 2026 zawatton
;; This file is part of nelix-core.  GPL-3.0-or-later.

;;; Commentary:

;; Phase 7-C ERT coverage for the node and haskell build-system
;; renderers plus node's required hash validation.

;;; Code:

(require 'ert)
(require 'nelix-dsl)

(ert-deftest nelix-core-buildsys-test-render-node ()
  "Renderer emits buildNpmPackage and npmDepsHash for node build-system."
  (let* ((ir '(:name my-node-tool
               :version "1.2.3"
               :source (:type url-fetch
                        :url "https://example.com/my-node-tool-1.2.3.tar.gz"
                        :sha256 "sha256-node-src")
               :build-system (:type node :npm-deps-hash "sha256-node-deps")))
         (out (nelix-core-render-nix ir)))
    (should (string-match-p (regexp-quote "pkgs.buildNpmPackage {") out))
    (should (string-match-p (regexp-quote "  pname = \"my-node-tool\";") out))
    (should (string-match-p (regexp-quote "  src = pkgs.fetchurl {") out))
    (should (string-match-p (regexp-quote "  npmDepsHash = \"sha256-node-deps\";")
                            out))))

(ert-deftest nelix-core-buildsys-test-render-haskell ()
  "Renderer emits haskellPackages.mkDerivation for haskell build-system."
  (let* ((ir '(:name my-haskell-tool
               :version "0.9.0"
               :source (:type url-fetch
                        :url "https://example.com/my-haskell-tool-0.9.0.tar.gz"
                        :sha256 "sha256-hs-src")
               :build-system (:type haskell)))
         (out (nelix-core-render-nix ir)))
    (should (string-match-p (regexp-quote "pkgs.haskellPackages.mkDerivation {")
                            out))
    (should (string-match-p (regexp-quote "  pname = \"my-haskell-tool\";") out))
    (should (string-match-p (regexp-quote "  src = pkgs.fetchurl {") out))))

(ert-deftest nelix-core-buildsys-test-node-requires-npm-deps-hash ()
  "Node build-system without :npm-deps-hash errors at parser."
  (should-error
   (macroexpand-1
    '(pkg-define foo
       (version "1.0")
       (source (url-fetch "https://x" :sha256 "y"))
       (build-system (node))))
   :type 'nelix-dsl-error))

(provide 'nelix-core-buildsys-test)
;;; nelix-core-buildsys-test.el ends here
