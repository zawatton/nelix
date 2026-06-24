;;; org-super-links.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "org-super-links"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/toshism/org-super-links/tar.gz/f6e13896b20560de6f3279703548774ea8d8a889" :sha256 "sha256-02d118c5ea16bd4a7b949603ffe78506451889b5dbf1b7df3be4c75d32c1797c") :dependencies nil :install (:type build :build-system emacs-package :pname "org-super-links" :load-paths (".") :features (org-super-links)))))

;;; org-super-links.el ends here
