;;; truename-cache.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "truename-cache"
 :version "0.3.7"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/meedstrom/truename-cache/tar.gz/0.3.7" :sha256 "sha256-fe029c94561c06648216ab753bc4176ddf7a9ea2d3920a1de10d4bd3b6d3ed25") :dependencies nil :install (:type build :build-system emacs-package :pname "truename-cache" :load-paths (".") :features (truename-cache)))))

;;; truename-cache.el ends here
