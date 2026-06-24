;;; edraw.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "edraw"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/misohena/el-easydraw/tar.gz/1caace5c9b25b659d64f96c0c44015a9514e960f" :sha256 "sha256-db8a17445f2d25d63581e958a54959b11916168df5131f864e889f33fb390ee2") :dependencies nil :install (:type build :build-system emacs-package :pname "edraw" :load-paths (".") :features (edraw)))))

;;; edraw.el ends here
