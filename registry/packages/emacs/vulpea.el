;;; vulpea.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "vulpea"
 :version "2.2.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/d12frosted/vulpea/tar.gz/v2.2.0" :sha256 "sha256-52575fc7fc5bcf8a42861a7ad8b7f5b88924b7c4fad1b78846817a25179a5d57") :dependencies ("emacsql" "s" "dash" "org") :install (:type build :build-system emacs-package :pname "vulpea" :load-paths (".") :features (vulpea)))))

;;; vulpea.el ends here
