;;; cider.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "cider"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/clojure-emacs/cider/tar.gz/87b836f289d5e3935b515eaac2959bd2e1d3ed37" :sha256 "sha256-9360b7dc3b4641c9894b9488a29810693ef0f892e14f5c68452d619f2b2f4baa") :dependencies nil :install (:type build :build-system emacs-package :pname "cider" :load-paths (".") :features (cider)))))

;;; cider.el ends here
