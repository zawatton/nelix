;;; adaptive-wrap.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "adaptive-wrap"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsmirror/adaptive-wrap/tar.gz/cb759c0ad5a3203464687c09dbe0e56464c2126e" :sha256 "sha256-74b73fd7326cc69c75c4d11a28536e28be44cd2778efd0348edf74e54aa11e7b") :dependencies nil :install (:type build :build-system emacs-package :pname "adaptive-wrap" :load-paths (".") :features (adaptive-wrap)))))

;;; adaptive-wrap.el ends here
