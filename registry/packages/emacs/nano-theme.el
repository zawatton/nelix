;;; nano-theme.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "nano-theme"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/rougier/nano-theme/tar.gz/ffe414c8af9c673caf8b8b05ba89a229cb9ad48b" :sha256 "sha256-91695e08ca8983915f3bae6d53c091e17814f2d36a689efeb0277054d2b8f06b") :dependencies nil :install (:type build :build-system emacs-package :pname "nano-theme" :load-paths (".") :features (nano-theme)))))

;;; nano-theme.el ends here
