;;; elfeed-summarize.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "elfeed-summarize"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/fritzgrabo/elfeed-summarize/tar.gz/main" :sha256 "sha256-d662f963175a4868111fa93de213f25b1941ba7ef98e71838b415a537c6a3398") :dependencies nil :install (:type build :build-system emacs-package :pname "elfeed-summarize" :load-paths (".") :features (elfeed-summarize)))))

;;; elfeed-summarize.el ends here
