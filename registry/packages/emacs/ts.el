;;; ts.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ts"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/ts.el/tar.gz/552936017cfdec89f7fc20c254ae6b37c3f22c5b" :sha256 "sha256-eae49670e5ca7dbf722b25f8ad3a1a66925be948e5b6e63da1ce0335e981eca6") :dependencies nil :install (:type build :build-system emacs-package :pname "ts" :load-paths (".") :features (ts)))))

;;; ts.el ends here
