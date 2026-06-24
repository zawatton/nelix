;;; ob-mermaid.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "ob-mermaid"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/arnm/ob-mermaid/tar.gz/9c895330d532427522f13b1b9ca9934c7f90c135" :sha256 "sha256-9ba36a6d65902cf844b23c2a7699820c4c31994a39cdf378fbb7622269e8ece0") :dependencies nil :install (:type build :build-system emacs-package :pname "ob-mermaid" :load-paths (".") :features (ob-mermaid)))))

;;; ob-mermaid.el ends here
