;;; htmlize.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "htmlize"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/hniksic/emacs-htmlize/tar.gz/ed5e5b05fd260e8f161a488d56f10e7f6e01fb75" :sha256 "sha256-8e0677dc3723bd9af4bdb6755707a0d65db189d5f9506509e99998c45da5ec15") :dependencies nil :install (:type build :build-system emacs-package :pname "htmlize" :load-paths (".") :features (htmlize)))))

;;; htmlize.el ends here
