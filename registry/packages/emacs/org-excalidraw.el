;;; org-excalidraw.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-excalidraw"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/zawatton/org-draw/tar.gz/7d9eee4e22102445772c7ddeeb85d91e995e14e1" :sha256 "sha256-5f41e17f30c59060be9f339f2e9d2c45861dbf18e19f919c2b8bcf27b984488f") :dependencies nil :install (:type build :build-system emacs-package :pname "org-excalidraw" :load-paths (".") :features (org-excalidraw)))))

;;; org-excalidraw.el ends here
