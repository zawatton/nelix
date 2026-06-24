;;; json-snatcher.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "json-snatcher"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Sterlingg/json-snatcher/tar.gz/b28d1c0670636da6db508d03872d96ffddbc10f2" :sha256 "sha256-ae9cdd2c583285797a6497b451a9325d950ee3a587bad073fed26922d51c1e59") :dependencies nil :install (:type build :build-system emacs-package :pname "json-snatcher" :load-paths (".") :features (json-snatcher)))))

;;; json-snatcher.el ends here
