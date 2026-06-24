;;; org-mem.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-mem"
 :version "0.34.1"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/meedstrom/org-mem/tar.gz/0.34.1" :sha256 "sha256-035a5f2086cc3bbebb2bce647e9f695dee4b61152205eb38377153f565cb86a2") :dependencies nil :install (:type build :build-system emacs-package :pname "org-mem" :load-paths (".") :features (org-mem)))))

;;; org-mem.el ends here
