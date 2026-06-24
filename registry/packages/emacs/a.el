;;; a.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "a"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/plexus/a.el/tar.gz/9ad2d18252b729174fe22ed0b2b7670c88f60c31" :sha256 "sha256-bd5c2f8964c750e199a090a59f51bbc926cee0eb0a4dd72da03c20b91ebb8450") :dependencies nil :install (:type build :build-system emacs-package :pname "a" :load-paths (".") :features (a)))))

;;; a.el ends here
