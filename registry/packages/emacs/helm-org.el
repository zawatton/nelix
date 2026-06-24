;;; helm-org.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "helm-org"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-helm/helm-org/tar.gz/9b7d5d4fd18180b2009a0f2b908c84d5363e41f3" :sha256 "sha256-5a33aa331a5e46f0a69b9ea80eded5a3a54a02164086e2028bb74cdf8a2cc6c6") :dependencies nil :install (:type build :build-system emacs-package :pname "helm-org" :load-paths (".") :features (helm-org)))))

;;; helm-org.el ends here
