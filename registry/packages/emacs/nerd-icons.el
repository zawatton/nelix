;;; nerd-icons.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "nerd-icons"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/rainstormstudio/nerd-icons.el/tar.gz/c3d641d8e14bd11b5f98372da34ee5313636e363" :sha256 "sha256-b5c74ece8e5983989dca88ef828aca9f26ead7a5df76afa9bff517fba55d489e") :dependencies nil :install (:type build :build-system emacs-package :pname "nerd-icons" :load-paths (".") :features (nerd-icons)))))

;;; nerd-icons.el ends here
