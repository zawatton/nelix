;;; cp5022x.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "cp5022x"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/awasira/cp5022x.el/tar.gz/ea7327dd75e54539576916f592ae1be98179ae35" :sha256 "sha256-60fcc306f5d7dbab4cc30f41c81863ef410e13f420f67a9983fdb3d1a9a425c1") :dependencies nil :install (:type build :build-system emacs-package :pname "cp5022x" :load-paths (".") :features (cp5022x)))))

;;; cp5022x.el ends here
