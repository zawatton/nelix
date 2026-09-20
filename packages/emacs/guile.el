;;; guile.el --- Nelix recipe (emacs-geiser/guile, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "guile" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/emacs-geiser/guile/-/archive/5a856c2982030ff77e2d151ead4fcd991512f362/guile-5a856c2982030ff77e2d151ead4fcd991512f362.tar.gz" :sha256 "sha256-673603f21fd00eafa9d76c5b2ae6d09f7cfe8cb18d9c36da0e86c1b23431561e") :dependencies ("geiser") :install (:type build :build-system emacs-package :pname "guile" :load-paths (".") :features (geiser-guile))) (x86_64-windows :source (:type url :url "https://gitlab.com/emacs-geiser/guile/-/archive/5a856c2982030ff77e2d151ead4fcd991512f362/guile-5a856c2982030ff77e2d151ead4fcd991512f362.tar.gz" :sha256 "sha256-673603f21fd00eafa9d76c5b2ae6d09f7cfe8cb18d9c36da0e86c1b23431561e") :dependencies ("geiser") :install (:type build :build-system emacs-package :pname "guile" :load-paths (".") :features (geiser-guile)))))

;;; guile.el ends here
