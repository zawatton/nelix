;;; package-lint.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "package-lint"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/purcell/package-lint/tar.gz/6f05a369e0718e93c5dce0951cad5e6646296612" :sha256 "sha256-1b10921383ee395585663f5b0dc8c389dfaed09c5459e4d6277682a0e3f90c98") :dependencies nil :install (:type build :build-system emacs-package :pname "package-lint" :load-paths (".") :features (package-lint)))))

;;; package-lint.el ends here
