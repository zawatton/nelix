;;; plz-media-type.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "plz-media-type"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/r0man/plz-media-type/tar.gz/main" :sha256 "sha256-5ae20b1f7f61b7809972cad85a5e62cdb1419ddef067205b1360340818795924") :dependencies nil :install (:type build :build-system emacs-package :pname "plz-media-type" :load-paths (".") :features (plz-media-type)))))

;;; plz-media-type.el ends here
