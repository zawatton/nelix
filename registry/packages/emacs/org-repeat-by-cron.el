;;; org-repeat-by-cron.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-repeat-by-cron"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/TomoeMami/org-repeat-by-cron.el/tar.gz/main" :sha256 "sha256-9f5ce3b8c59bba3d0be026e4b39517fcb4161457ccec3b3aa49b4f27548aa4ab") :dependencies nil :install (:type build :build-system emacs-package :pname "org-repeat-by-cron" :load-paths (".") :features (org-repeat-by-cron)))))

;;; org-repeat-by-cron.el ends here
