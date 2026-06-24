;;; mu4easy.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "mu4easy"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/danielfleischer/mu4easy/tar.gz/d99c384ca921bb0423c7a743ce6efa9629101b0d" :sha256 "sha256-2183dfb8885763ea071e95d9153176989c68de245f0d28da9cc75706a2cf4731") :dependencies nil :install (:type build :build-system emacs-package :pname "mu4easy" :load-paths (".") :features (mu4easy)))))

;;; mu4easy.el ends here
