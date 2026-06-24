;;; yaml-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "yaml-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/yoshiki/yaml-mode/tar.gz/7b5ce294fb15c2c8926fa476d7218aa415550a2a" :sha256 "sha256-c1a0e9e83638a33771d3717a8239a550272f8eb45bbdcd8899cc4bdb109e4370") :dependencies nil :install (:type build :build-system emacs-package :pname "yaml-mode" :load-paths (".") :features (yaml-mode)))))

;;; yaml-mode.el ends here
