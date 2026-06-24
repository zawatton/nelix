;;; undo-tree.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "undo-tree"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsmirror/undo-tree/tar.gz/f55637665de4dc1f3d8cae28f456a84b3a5655f8" :sha256 "sha256-4d6f7517da8064611b5475acdb275a4da2ec177b33330759514167bf9a6e9ddc") :dependencies ("queue") :install (:type build :build-system emacs-package :pname "undo-tree" :load-paths (".") :features (undo-tree)))))

;;; undo-tree.el ends here
