;;; doom-themes.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "doom-themes"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/doomemacs/themes/tar.gz/88126db5e63d816533d0372cb99246b842cac74e" :sha256 "sha256-86ac4c20be7bbda6c7906900e250dcd4821e61bc18e6eb1146a60e6d6abe9a65") :dependencies nil :install (:type build :build-system emacs-package :pname "doom-themes" :load-paths (".") :features (doom-themes)))))

;;; doom-themes.el ends here
