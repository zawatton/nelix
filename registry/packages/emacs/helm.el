;;; helm.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "helm"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-helm/helm/tar.gz/99f34406aab956ea9420c592bbfd676e043344e6" :sha256 "sha256-9374c32c219f81221a536d98db9b5df83a6107eaf958b9ab4fd2d9ebf2cd10d3") :dependencies nil :install (:type build :build-system emacs-package :pname "helm" :load-paths (".") :features (helm)))))

;;; helm.el ends here
