;;; eshell-syntax-highlighting.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "eshell-syntax-highlighting"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/akreisher/eshell-syntax-highlighting/tar.gz/26f49633308ea876b5850256e07622de34ad0bdd" :sha256 "sha256-e1025319d691c63d114dbe884b380984d7690cfa8ae12e2db33084d076aa0008") :dependencies nil :install (:type build :build-system emacs-package :pname "eshell-syntax-highlighting" :load-paths (".") :features (eshell-syntax-highlighting)))))

;;; eshell-syntax-highlighting.el ends here
