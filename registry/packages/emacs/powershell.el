;;; powershell.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "powershell"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/jschaf/powershell.el/tar.gz/38727f1cdaf0c937a62b68ee52ec7196b8149f93" :sha256 "sha256-1a6c7a7027040b589e71080804ac1369321c1a6123b76a89c9dee27f641ac1c0") :dependencies nil :install (:type build :build-system emacs-package :pname "powershell" :load-paths (".") :features (powershell)))))

;;; powershell.el ends here
