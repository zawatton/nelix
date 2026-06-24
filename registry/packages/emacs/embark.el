;;; embark.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "embark"
 :version "1.1"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/oantolin/embark/tar.gz/1.1" :sha256 "sha256-30d15b2006132b2ad4618ff1ffc0c3c614ece714a3b7fbe9ec28ee27fdde4707") :dependencies nil :install (:type build :build-system emacs-package :pname "embark" :load-paths (".") :features (embark)))))

;;; embark.el ends here
