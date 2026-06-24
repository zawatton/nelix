;;; org-transclusion.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-transclusion"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/nobiot/org-transclusion/tar.gz/e6e638710e90198070c9b07ebdaa345a79f74706" :sha256 "sha256-f834219e7df355ab04bcc64b92419610f86cc87a6b54add1ee6401314dfb4400") :dependencies nil :install (:type build :build-system emacs-package :pname "org-transclusion" :load-paths (".") :features (org-transclusion)))))

;;; org-transclusion.el ends here
