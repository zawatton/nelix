;;; dracula-theme.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "dracula-theme"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/dracula/emacs/tar.gz/8b3a005db9e8b7ac57e683bc6631cdc7643e8150" :sha256 "sha256-50ba815eb74e4bc6785489daf88f37d5e742bedc85818919644d0f619ec963e5") :dependencies nil :install (:type build :build-system emacs-package :pname "dracula-theme" :load-paths (".") :features (dracula-theme)))))

;;; dracula-theme.el ends here
