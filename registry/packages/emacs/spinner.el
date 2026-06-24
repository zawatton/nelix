;;; spinner.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "spinner"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Malabarba/spinner.el/tar.gz/d4647ae87fb0cd24bc9081a3d287c860ff061c21" :sha256 "sha256-6f04366936417b08a9e49e75087bcc8645d303ccf93cb5dae0d84278d37fc0de") :dependencies nil :install (:type build :build-system emacs-package :pname "spinner" :load-paths (".") :features (spinner)))))

;;; spinner.el ends here
