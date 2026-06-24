;;; org-supertag.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-supertag"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/yibie/org-supertag/tar.gz/53bdfc9d1236d85fbc5d7ce8e771be2bb4efbddc" :sha256 "sha256-c14b6f403e11e9bcba4cbef6b35270faf2021bd8a87be4d51952a6e06b48a395") :dependencies ("org" "ht" "gptel" "posframe") :install (:type build :build-system emacs-package :pname "org-supertag" :load-paths (".") :features (org-supertag)))))

;;; org-supertag.el ends here
