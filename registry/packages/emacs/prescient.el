;;; prescient.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "prescient"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/radian-software/prescient.el/tar.gz/2b8a8b41228bddb2e11eb1c200e98a9edd04797c" :sha256 "sha256-58cc05921e4e33d1e142357a1ed31863c4a018c58064e3033cbb24affe253d4f") :dependencies nil :install (:type build :build-system emacs-package :pname "prescient" :load-paths (".") :features (prescient)))))

;;; prescient.el ends here
