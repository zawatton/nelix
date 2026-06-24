;;; consult.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "consult"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/minad/consult/tar.gz/0c3f53916ea0db0c472c0a0c620a85cc1b00caf2" :sha256 "sha256-d2eb5ca518ed57648d1377194436c4167dd46171245e8294229a1550cae5e372") :dependencies nil :install (:type build :build-system emacs-package :pname "consult" :load-paths (".") :features (consult)))))

;;; consult.el ends here
