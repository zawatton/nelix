;;; web-server.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "web-server"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/eschulte/emacs-web-server/tar.gz/6357a1c2d1718778503f7ee0909585094117525b" :sha256 "sha256-2a1e9acd13512f25f01498c0f2d82d0519bf529a13090bb36adb956e16b9b36c") :dependencies nil :install (:type build :build-system emacs-package :pname "web-server" :load-paths (".") :features (web-server)))))

;;; web-server.el ends here
