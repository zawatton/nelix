;;; theme-changer.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "theme-changer"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/hadronzoo/theme-changer/tar.gz/7febd7632451bb99a5d92f24623432c4de035ff1" :sha256 "sha256-933927b81825e3df654004abcb2ca7cbcb85f53ed418ab3a9c437e8ec490a096") :dependencies nil :install (:type build :build-system emacs-package :pname "theme-changer" :load-paths (".") :features (theme-changer)))))

;;; theme-changer.el ends here
