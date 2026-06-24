;;; pfuture.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "pfuture"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Alexander-Miller/pfuture/tar.gz/19b53aebbc0f2da31de6326c495038901bffb73c" :sha256 "sha256-da9937fb043cbf252f1e225439cf8c007af9eee04bdeb2a55fe48b036d893c3f") :dependencies nil :install (:type build :build-system emacs-package :pname "pfuture" :load-paths (".") :features (pfuture)))))

;;; pfuture.el ends here
