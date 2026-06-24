;;; vimrc-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "vimrc-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/mcandre/vimrc-mode/tar.gz/13bc150a870d5d4a95f1111e4740e2b22813c30e" :sha256 "sha256-eafc1c0c819dbf5ea5bb6d5c605d00e60271af721322cb753391233fd9e5a07e") :dependencies nil :install (:type build :build-system emacs-package :pname "vimrc-mode" :load-paths (".") :features (vimrc-mode)))))

;;; vimrc-mode.el ends here
