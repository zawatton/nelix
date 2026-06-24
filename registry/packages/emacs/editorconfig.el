;;; editorconfig.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "editorconfig"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/editorconfig/editorconfig-emacs/tar.gz/648f0cf9aeb72db77b252832a58367332b7bc055" :sha256 "sha256-ce3209612f0e8c5dfd2fc6a8b10d491d44d2e20d0a6cfb2a02142fc7a2b4591e") :dependencies nil :install (:type build :build-system emacs-package :pname "editorconfig" :load-paths (".") :features (editorconfig)))))

;;; editorconfig.el ends here
