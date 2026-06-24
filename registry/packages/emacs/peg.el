;;; peg.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "peg"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-straight/peg/tar.gz/c9155d5586909953861421ce05a341d59b53fa73" :sha256 "sha256-aa62b8b37780449a7730773d7022ac05cb32dca5ef325dd3d5d5f782c37fe2a9") :dependencies nil :install (:type build :build-system emacs-package :pname "peg" :load-paths (".") :features (peg)))))

;;; peg.el ends here
