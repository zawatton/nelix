;;; s.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "s"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magnars/s.el/tar.gz/b4b8c03fcef316a27f75633fe4bb990aeff6e705" :sha256 "sha256-971a632af64d9ff9d2fd64fa5e9476b29d17b3977401009077cefa899889df17") :dependencies nil :install (:type build :build-system emacs-package :pname "s" :load-paths (".") :features (s)))))

;;; s.el ends here
