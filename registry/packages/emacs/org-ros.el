;;; org-ros.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-ros"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/LionyxML/ros/tar.gz/50e16f5031d281458bd574f07aad16c0d1d18663" :sha256 "sha256-719e630d458870e03742859414c87799fe875252521bed7f197fcee426099ef2") :dependencies nil :install (:type build :build-system emacs-package :pname "org-ros" :load-paths (".") :features (org-ros)))))

;;; org-ros.el ends here
