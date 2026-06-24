;;; orderless.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "orderless"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/oantolin/orderless/tar.gz/416c62a4a8e7199567a5df63d03cf320dc4d6ab0" :sha256 "sha256-e3b2b715e7c6563302ff87c6b95ee6dd39dbec8520a4631889fcfc976d25e835") :dependencies nil :install (:type build :build-system emacs-package :pname "orderless" :load-paths (".") :features (orderless)))))

;;; orderless.el ends here
