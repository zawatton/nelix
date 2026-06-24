;;; async.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "async"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jwiegley/emacs-async/tar.gz/f317b0c9c3e60a959f45d035ed5e31a78f1263ac" :sha256 "sha256-386280fdef75630d444d96aae3cc6040fd6c021d29185d098b559773833fd494") :dependencies nil :install (:type build :build-system emacs-package :pname "async" :load-paths (".") :features (async)))))

;;; async.el ends here
