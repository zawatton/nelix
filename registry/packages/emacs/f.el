;;; f.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "f"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/rejeep/f.el/tar.gz/1e7020dc0d4c52d3da9bd610d431cab13aa02d8c" :sha256 "sha256-b101773b7170ad196fc4d3486f11a6e9f7578f956ad1c6d78dd637e73922dc06") :dependencies nil :install (:type build :build-system emacs-package :pname "f" :load-paths (".") :features (f)))))

;;; f.el ends here
