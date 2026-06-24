;;; solaire-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "solaire-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/hlissner/emacs-solaire-mode/tar.gz/c9334666bd208f3322e6118d30eba1b2438e2bb9" :sha256 "sha256-8c5a981cb4e1309633f5c4bc6173dc83d4d66586390fe55be72862d739baa9f3") :dependencies nil :install (:type build :build-system emacs-package :pname "solaire-mode" :load-paths (".") :features (solaire-mode)))))

;;; solaire-mode.el ends here
