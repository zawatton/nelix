;;; buttercup.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "buttercup"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jorgenschaefer/emacs-buttercup/tar.gz/bf01a33f8bc2d3664121d3b20f7496e67ce55e6a" :sha256 "sha256-1f1f66303670729f8d176166038736c95590f9c33b67996782af018d459dba6b") :dependencies nil :install (:type build :build-system emacs-package :pname "buttercup" :load-paths (".") :features (buttercup)))))

;;; buttercup.el ends here
