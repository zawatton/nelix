;;; elisp-lint.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "elisp-lint"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/gonewest818/elisp-lint/tar.gz/c5765abf75fd1ad22505b349ae1e6be5303426c2" :sha256 "sha256-f04b3d21bec65ff5139a61bb7b363ebc86350a1d5dd757979473d154881962fd") :dependencies nil :install (:type build :build-system emacs-package :pname "elisp-lint" :load-paths (".") :features (elisp-lint)))))

;;; elisp-lint.el ends here
