;;; cond-let.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "cond-let"
 :version "v0.2.2"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tarsius/cond-let/tar.gz/v0.2.2" :sha256 "sha256-c7a152076941f88e0b1b239f62f53483231a97022e8f6d06ae070b5b29ef2e69") :dependencies nil :install (:type build :build-system emacs-package :pname "cond-let" :load-paths (".") :features (cond-let)))))

;;; cond-let.el ends here
