;;; plz.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "plz" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/plz.el/tar.gz/e2d07838e3b64ee5ebe59d4c3c9011adefb7b58e" :sha256 "sha256-3b9f8cdd984d2b058f9e15e8641262c33bbe6188b9ae929508c853954b48c868") :dependencies nil :install (:type build :build-system emacs-package :pname "plz" :load-paths (".") :tar-exclude ("NOTES.org") :features (plz))) (x86_64-windows :source (:type url :url "https://codeload.github.com/alphapapa/plz.el/tar.gz/e2d07838e3b64ee5ebe59d4c3c9011adefb7b58e" :sha256 "sha256-3b9f8cdd984d2b058f9e15e8641262c33bbe6188b9ae929508c853954b48c868") :dependencies nil :install (:type build :build-system emacs-package :pname "plz" :load-paths (".") :tar-exclude ("NOTES.org") :features (plz)))))

;;; plz.el ends here
