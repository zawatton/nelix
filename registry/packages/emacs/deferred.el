;;; deferred.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "deferred"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/kiwanami/emacs-deferred/tar.gz/2239671d94b38d92e9b28d4e12fd79814cfb9c16" :sha256 "sha256-bea0ce3a30545af531385eb75296ade88212e3b5ccce2bc302064893c999951b") :dependencies nil :install (:type build :build-system emacs-package :pname "deferred" :load-paths (".") :features (deferred)))))

;;; deferred.el ends here
