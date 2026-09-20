;;; geiser.el --- Nelix recipe (emacs-geiser/geiser, GitLab) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "geiser" :version "0.0.0" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://gitlab.com/emacs-geiser/geiser/-/archive/32196db8f8ddab071565a5ae6d799ada4f8fbe6b/geiser-32196db8f8ddab071565a5ae6d799ada4f8fbe6b.tar.gz" :sha256 "sha256-da0b66f4a24f72cbb8f4affb71a049d383df51bbd8b7969cb8b95f20e4642f2d") :dependencies nil :install (:type build :build-system emacs-package :pname "geiser" :load-paths ("." "elisp") :features (geiser))) (x86_64-windows :source (:type url :url "https://gitlab.com/emacs-geiser/geiser/-/archive/32196db8f8ddab071565a5ae6d799ada4f8fbe6b/geiser-32196db8f8ddab071565a5ae6d799ada4f8fbe6b.tar.gz" :sha256 "sha256-da0b66f4a24f72cbb8f4affb71a049d383df51bbd8b7969cb8b95f20e4642f2d") :dependencies nil :install (:type build :build-system emacs-package :pname "geiser" :load-paths ("." "elisp") :features (geiser)))))

;;; geiser.el ends here
