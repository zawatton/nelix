;;; minions.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "minions"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/tarsius/minions/tar.gz/413b95a0d1c7c10d0f8d440d1982062b73d5ea4a" :sha256 "sha256-1f852f723f7c8ef49ff6b69f303f5748fc93897db1daf43929a9783e596cee8c") :dependencies nil :install (:type build :build-system emacs-package :pname "minions" :load-paths (".") :features (minions)))))

;;; minions.el ends here
