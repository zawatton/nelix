;;; gcmh.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "gcmh"
 :version "0.2.1"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsmirror/gcmh/tar.gz/0089f9c3a6d4e9a310d0791cf6fa8f35642ecfd9" :sha256 "sha256-18ece4a9c09ef0b33be2bae3cafabf79645448f999402d0340258b4c0546482c") :dependencies nil :install (:type build :build-system emacs-package :pname "gcmh" :load-paths (".") :features (gcmh)))))

;;; gcmh.el ends here
