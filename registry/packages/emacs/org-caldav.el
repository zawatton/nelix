;;; org-caldav.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-caldav"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/dengste/org-caldav/tar.gz/6a2683211baa4b4efed0ca210275bf68dbbcfc4f" :sha256 "sha256-158200df274195be8e627b75fad88126d0a5d4feb21ab5a0adc4ec49a1b008b5") :dependencies nil :install (:type build :build-system emacs-package :pname "org-caldav" :load-paths (".") :features (org-caldav)))))

;;; org-caldav.el ends here
