;;; markdown-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "markdown-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jrblevin/markdown-mode/tar.gz/6102ac5b7301b4c4fc0262d9c6516693d5a33f2b" :sha256 "sha256-140e4556d0b088128132f945e424c751fb41124f345161031dc515f8b0b87f06") :dependencies nil :install (:type build :build-system emacs-package :pname "markdown-mode" :load-paths (".") :features (markdown-mode)))))

;;; markdown-mode.el ends here
