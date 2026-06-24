;;; transient.el --- Nelix recipe (manual pin; missing transitive dep) -*- lexical-binding: t; -*-

;; transient was never a top-level block in flake.nix: nixpkgs supplied it
;; as a propagated dependency of magit's melpaBuild.  Off Nix, that implicit
;; edge is gone, so magit (and magit-todos / magit-delta) cannot load without
;; a native transient.  Pinned by full commit (v0.13.4) with the real tarball
;; sha256.  Lives under lisp/, which the emacs-package preset load-path
;; detector picks up automatically.

(require 'nelix-registry)

(nelix-package
 :name "transient"
 :version "0.13.4"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magit/transient/tar.gz/1856230dc181f23dd15026b0ad21d8b299b034d1" :sha256 "sha256-dfc304b615d39c9c40b5f19381f0a6cae84f7ddbf9dda0db1bfc84a82a199be1") :dependencies ("compat") :install (:type build :build-system emacs-package :pname "transient" :load-paths (".") :features (transient)))))

;;; transient.el ends here
