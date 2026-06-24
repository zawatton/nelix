;;; mozc.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "mozc"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/google/mozc/tar.gz/5e6abfe1853b080766def432b746a9bed79e54b0" :sha256 "sha256-f9509e75a5611c70c573273a4617c97c681f39a98b023a4d3ad0371fe44b92ae") :dependencies nil :install (:type build :build-system emacs-package :pname "mozc" :load-paths (".") :features (mozc)))))

;;; mozc.el ends here
