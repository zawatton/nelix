;;; typescript-mode.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "typescript-mode"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacs-typescript/typescript.el/tar.gz/5bb294411ff06ad40186bb7ca141fdbfff902e09" :sha256 "sha256-941df67eadc4372448603a871f9afcf6ff0f22baa7ec463dd02a3e39a8ba6689") :dependencies nil :install (:type build :build-system emacs-package :pname "typescript-mode" :load-paths (".") :features (typescript-mode)))))

;;; typescript-mode.el ends here
