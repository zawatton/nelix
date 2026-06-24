;;; treemacs.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "treemacs"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Alexander-Miller/treemacs/tar.gz/488dfc0a3aa7c1d35802d4f89be058e761578663" :sha256 "sha256-231f9631afed62f800a4caf89e91d3578fe7a8f4d961c8e801675c776ae56956") :dependencies nil :install (:type build :build-system emacs-package :pname "treemacs" :load-paths (".") :features (treemacs)))))

;;; treemacs.el ends here
