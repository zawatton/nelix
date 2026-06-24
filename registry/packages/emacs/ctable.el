;;; ctable.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ctable"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/kiwanami/emacs-ctable/tar.gz/48b73742757a3ae5736d825fe49e00034cc453b5" :sha256 "sha256-0c36e8eaeaa56a7d70cbafae62d4d47a8375cb28e94567aa4c0b0b4ca7aaaea0") :dependencies nil :install (:type build :build-system emacs-package :pname "ctable" :load-paths (".") :features (ctable)))))

;;; ctable.el ends here
