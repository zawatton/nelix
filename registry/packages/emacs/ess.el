;;; ess.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ess"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-ess/ESS/tar.gz/0eb240bcb6d0e933615f6cfaa9761b629ddbabdd" :sha256 "sha256-5aba0b5624d778d997d5096057d6044603b995880fe177ac1246a07ecc4ed6fd") :dependencies nil :install (:type build :build-system emacs-package :pname "ess" :load-paths (".") :features (ess)))))

;;; ess.el ends here
