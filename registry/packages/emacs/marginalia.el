;;; marginalia.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "marginalia"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/minad/marginalia/tar.gz/c34fdacce64168cb20d710a87e66cc9d1f795a82" :sha256 "sha256-27217f6b273e474de29d2ba2e896b9b66d85647f3f00d3f6d3638e1a4fb7133c") :dependencies nil :install (:type build :build-system emacs-package :pname "marginalia" :load-paths (".") :features (marginalia)))))

;;; marginalia.el ends here
