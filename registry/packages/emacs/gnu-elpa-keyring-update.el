;;; gnu-elpa-keyring-update.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "gnu-elpa-keyring-update"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsmirror/gnu-elpa-keyring-update/tar.gz/1e8726c459258fba62ee38807abdae4e350e5238" :sha256 "sha256-55a595acd6b023f28880582124a3e4af8f268c87e5e2aecd07b7f366c440f0b1") :dependencies nil :install (:type build :build-system emacs-package :pname "gnu-elpa-keyring-update" :load-paths (".") :features (gnu-elpa-keyring-update)))))

;;; gnu-elpa-keyring-update.el ends here
