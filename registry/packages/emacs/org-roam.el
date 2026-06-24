;;; org-roam.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-roam"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/org-roam/org-roam/tar.gz/3e186a85520f02c1672150f62eb921bcad5d2c2d" :sha256 "sha256-a0d3c5a88626f47f8134e06447fc7cccef51604010eb7985e14f13f9876bc952") :dependencies ("dash" "emacsql" "magit-section" "org") :install (:type build :build-system emacs-package :pname "org-roam" :load-paths (".") :features (org-roam)))))

;;; org-roam.el ends here
