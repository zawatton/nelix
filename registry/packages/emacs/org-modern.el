;;; org-modern.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-modern"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/minad/org-modern/tar.gz/5b7e8195744f9b6a14a5c72bd13ae52e86952d72" :sha256 "sha256-7d6a24b0a67e28803c8ee9e146845ba5288d4017e8634071746fbbed4e7484e5") :dependencies nil :install (:type build :build-system emacs-package :pname "org-modern" :load-paths (".") :features (org-modern)))))

;;; org-modern.el ends here
