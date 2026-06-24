;;; org-fragtog.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-fragtog"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/io12/org-fragtog/tar.gz/c675563af3f9ab5558cfd5ea460e2a07477b0cfd" :sha256 "sha256-c8ee2facdcc6daa366d0b66af69ba3edc84edba1b6ba6a9a3706e955778ea72e") :dependencies nil :install (:type build :build-system emacs-package :pname "org-fragtog" :load-paths (".") :features (org-fragtog)))))

;;; org-fragtog.el ends here
