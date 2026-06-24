;;; ht.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ht"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Wilfred/ht.el/tar.gz/1c49aad1c820c86f7ee35bf9fff8429502f60fef" :sha256 "sha256-a53201831517dfc0a9c7adc3992789bf9f1a86ec30f44252cfd7c240798e25fc") :dependencies nil :install (:type build :build-system emacs-package :pname "ht" :load-paths (".") :features (ht)))))

;;; ht.el ends here
