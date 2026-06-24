;;; which-key.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "which-key"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/justbur/emacs-which-key/tar.gz/ed389312170df955aaf10c2e120cc533ed5c509e" :sha256 "sha256-da77ec762bfaf9c4c873ca23452e77ff73b415c362b10b3135bb70577e40ec87") :dependencies nil :install (:type build :build-system emacs-package :pname "which-key" :load-paths (".") :features (which-key)))))

;;; which-key.el ends here
