;;; anzu.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "anzu"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacsorphanage/anzu/tar.gz/26fb50b429ee968eb944b0615dd0aed1dd66172c" :sha256 "sha256-63ff8cb19c8d2bd85a4979361fa8ccbdec0f6f6a0cd27c046f982ab19415bb0b") :dependencies nil :install (:type build :build-system emacs-package :pname "anzu" :load-paths (".") :features (anzu)))))

;;; anzu.el ends here
