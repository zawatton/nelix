;;; emojify.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "emojify"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/iqbalansari/emacs-emojify/tar.gz/cfa00865388809363df3f884b4dd554a5d44f835" :sha256 "sha256-f660355c846cc31f6ff50418e224fe7e99936222a4b8b7da3e52e542c192647b") :dependencies ("ht") :install (:type build :build-system emacs-package :pname "emojify" :load-paths (".") :features (emojify)))))

;;; emojify.el ends here
