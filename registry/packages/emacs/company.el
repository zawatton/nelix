;;; company.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "company"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/company-mode/company-mode/tar.gz/58542350fb6a949f5ed91616a715e79ee42bd8a8" :sha256 "sha256-7930fa6e33a02882c78552c9fbf71d3db0f7a1203e303be8b730be9da35d8cf1") :dependencies nil :install (:type build :build-system emacs-package :pname "company" :load-paths (".") :features (company)))))

;;; company.el ends here
