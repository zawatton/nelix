;;; diff-hl.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "diff-hl"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/dgutov/diff-hl/tar.gz/b80ff9b4a772f7ea000e86fbf88175104ddf9557" :sha256 "sha256-baa2e95c0f486644a66812824422c65b904c0af656335f67a6724349eb3ebfcf") :dependencies nil :install (:type build :build-system emacs-package :pname "diff-hl" :load-paths (".") :features (diff-hl)))))

;;; diff-hl.el ends here
