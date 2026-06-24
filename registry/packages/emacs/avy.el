;;; avy.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "avy"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/avy/tar.gz/933d1f36cca0f71e4acb5fac707e9ae26c536264" :sha256 "sha256-caa7cf6e3fce79ebe93e7d961d117e09c2534004e50c5ddeecdb56b1cd01928d") :dependencies nil :install (:type build :build-system emacs-package :pname "avy" :load-paths (".") :features (avy)))))

;;; avy.el ends here
