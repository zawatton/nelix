;;; highlight-indent-guides.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "highlight-indent-guides"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/DarthFennec/highlight-indent-guides/tar.gz/cf352c85cd15dd18aa096ba9d9ab9b7ab493e8f6" :sha256 "sha256-2972e6e0d5a5a6502cc5d7d0301841f55503b3225bd0a47e173e3c53774ea29e") :dependencies nil :install (:type build :build-system emacs-package :pname "highlight-indent-guides" :load-paths (".") :features (highlight-indent-guides)))))

;;; highlight-indent-guides.el ends here
