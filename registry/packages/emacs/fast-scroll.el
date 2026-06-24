;;; fast-scroll.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "fast-scroll"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/ahungry/fast-scroll/tar.gz/3f6ca0d5556fe9795b74714304564f2295dcfa24" :sha256 "sha256-802b8838d1c9729cc2b1ef2a0d24926cba6b74799d0d3810e34cfb10231fef2e") :dependencies nil :install (:type build :build-system emacs-package :pname "fast-scroll" :load-paths (".") :features (fast-scroll)))))

;;; fast-scroll.el ends here
