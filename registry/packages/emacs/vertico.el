;;; vertico.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "vertico"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/minad/vertico/tar.gz/20562420881585cc3e5dbc10703a6906a6776d0d" :sha256 "sha256-f82bcfbfae75d3a72016f1e073edc5e93744e7c2b39f71ffd2b86f3274baec1f") :dependencies nil :install (:type build :build-system emacs-package :pname "vertico" :load-paths (".") :features (vertico)))))

;;; vertico.el ends here
