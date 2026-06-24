;;; projectile.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "projectile"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/bbatsov/projectile/tar.gz/002e52769e5fda5e03fb9069ae02b2d3763c92e8" :sha256 "sha256-2ebffeaa3b6f5e206f16a950133a6afb59d0b78a72a6f60484ca002098206ae1") :dependencies nil :install (:type build :build-system emacs-package :pname "projectile" :load-paths (".") :features (projectile)))))

;;; projectile.el ends here
