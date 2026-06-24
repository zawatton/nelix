;;; evil.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-evil/evil/tar.gz/ad3e95f6e3253ddf2d33377ebbff7c82082ab75a" :sha256 "sha256-afe767d44277c13668ad7486ede9d0e0c64705f2c25ea7a5949f2f64bb585847") :dependencies nil :install (:type build :build-system emacs-package :pname "evil" :load-paths (".") :features (evil)))))

;;; evil.el ends here
