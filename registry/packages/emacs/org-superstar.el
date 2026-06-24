;;; org-superstar.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-superstar"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/integral-dw/org-superstar-mode/tar.gz/29dbbc48ac925f36cc1636b36b4a3ccb3588e17f" :sha256 "sha256-8b3f394ba4659993baec46ed14f158f9c898a7c7918330cd0e420b774195ca06") :dependencies nil :install (:type build :build-system emacs-package :pname "org-superstar" :load-paths (".") :features (org-superstar)))))

;;; org-superstar.el ends here
