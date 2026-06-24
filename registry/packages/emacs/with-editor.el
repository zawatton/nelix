;;; with-editor.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "with-editor"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magit/with-editor/tar.gz/c319ef4d3a9dab479b4077cdc089d1ffac97d7db" :sha256 "sha256-30d5427f7233a0225e9879101db571567aed25b05db37a9e646e4ae856cf34d5") :dependencies ("compat") :install (:type build :build-system emacs-package :pname "with-editor" :load-paths (".") :features (with-editor)))))

;;; with-editor.el ends here
