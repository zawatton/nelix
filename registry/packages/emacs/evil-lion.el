;;; evil-lion.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "evil-lion"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/edkolev/evil-lion/tar.gz/4da660e124731ed65e7aaa6c067c30e876619429" :sha256 "sha256-1607b5790d0a0ead1a9433b053bdf207b2e1d557d6c3ec2fc834a98831684577") :dependencies nil :install (:type build :build-system emacs-package :pname "evil-lion" :load-paths (".") :features (evil-lion)))))

;;; evil-lion.el ends here
