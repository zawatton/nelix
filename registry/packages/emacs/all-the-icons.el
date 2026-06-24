;;; all-the-icons.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "all-the-icons"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/domtronn/all-the-icons.el/tar.gz/39ef44f810c34e8900978788467cc675870bcd19" :sha256 "sha256-30dd71f55819a52ab096a83621ac9bda194a80de9883407e8e0d4cb7a0919ef6") :dependencies nil :install (:type build :build-system emacs-package :pname "all-the-icons" :load-paths (".") :features (all-the-icons)))))

;;; all-the-icons.el ends here
