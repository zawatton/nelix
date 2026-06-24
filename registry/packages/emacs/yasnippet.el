;;; yasnippet.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "yasnippet"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/joaotavora/yasnippet/tar.gz/eb5ba2664c3a68ae4a53bb38b85418dd131b208f" :sha256 "sha256-9faf31108fc8b763e98c29403726c470e9ead8666f31c8d0a2eb0fbd9714250c") :dependencies nil :install (:type build :build-system emacs-package :pname "yasnippet" :load-paths (".") :features (yasnippet)))))

;;; yasnippet.el ends here
