;;; compat.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "compat"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-compat/compat/tar.gz/9a234d0d28cccd33f64faea6074fa2865a17c164" :sha256 "sha256-42c2dd1ff20e99a75023ee494d5570d00713466a0284e58dcf3eaa406f6194cd") :dependencies nil :install (:type build :build-system emacs-package :pname "compat" :load-paths (".") :features (compat)))))

;;; compat.el ends here
