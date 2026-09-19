;;; emacs-eat.el --- Nelix recipe (akib/emacs-eat, Codeberg) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "emacs-eat" :version "0.9.4" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeberg.org/akib/emacs-eat/archive/3a6f418f55d183b9d86f99c140caed4ba3d44f93.tar.gz" :sha256 "sha256-920a7b80d90708976e16093949dd8c6b85aee42430d64df0bf507c37d5d87b5d") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-eat" :load-paths (".") :features (eat))) (x86_64-windows :source (:type url :url "https://codeberg.org/akib/emacs-eat/archive/3a6f418f55d183b9d86f99c140caed4ba3d44f93.tar.gz" :sha256 "sha256-920a7b80d90708976e16093949dd8c6b85aee42430d64df0bf507c37d5d87b5d") :dependencies nil :install (:type build :build-system emacs-package :pname "emacs-eat" :load-paths (".") :features (eat)))))

;;; emacs-eat.el ends here
