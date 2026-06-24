;;; iedit.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "iedit"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/victorhge/iedit/tar.gz/dd5d75b38ee0c52ad81245a8e5c932d3f5c4772d" :sha256 "sha256-a708da5aacebf773e9d4e40f1787dfdfaa80e0e82267b0c19bf63d5a16fe0261") :dependencies nil :install (:type build :build-system emacs-package :pname "iedit" :load-paths (".") :features (iedit)))))

;;; iedit.el ends here
