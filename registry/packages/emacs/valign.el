;;; valign.el --- Nelix recipe (casouri/valign, GitHub) -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package :name "valign" :version "3.1.1" :class 'emacs-package :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/casouri/valign/tar.gz/c63faceba523f22f73df152cffcd54c41f997acd" :sha256 "sha256-93855f13770170100e871e1cdc1857b58490a7aa091479d6506c4a84b3939535") :dependencies nil :install (:type build :build-system emacs-package :pname "valign" :load-paths (".") :features (valign))) (x86_64-windows :source (:type url :url "https://codeload.github.com/casouri/valign/tar.gz/c63faceba523f22f73df152cffcd54c41f997acd" :sha256 "sha256-93855f13770170100e871e1cdc1857b58490a7aa091479d6506c4a84b3939535") :dependencies nil :install (:type build :build-system emacs-package :pname "valign" :load-paths (".") :features (valign)))))

;;; valign.el ends here
