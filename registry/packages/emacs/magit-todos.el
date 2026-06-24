;;; magit-todos.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "magit-todos"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/alphapapa/magit-todos/tar.gz/f777f26799cb44a36070ef5889022b8a3d6815ee" :sha256 "sha256-75bd0b2a88674bcadb5793a69afd491b1387269e0ac476fd5d9928fd03b22d65") :dependencies nil :install (:type build :build-system emacs-package :pname "magit-todos" :load-paths (".") :features (magit-todos)))))

;;; magit-todos.el ends here
