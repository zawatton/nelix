;;; org-download.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-download"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/org-download/tar.gz/19e166f0a8c539b4144cfbc614309d47a9b2a9b7" :sha256 "sha256-5c99999c65b3a5ce64e0ce1f3b9ce637520972a068faa37ef3cc292cc5334bb6") :dependencies ("async") :install (:type build :build-system emacs-package :pname "org-download" :load-paths (".") :features (org-download)))))

;;; org-download.el ends here
