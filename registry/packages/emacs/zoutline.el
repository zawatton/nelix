;;; zoutline.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "zoutline"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/abo-abo/zoutline/tar.gz/32857c6c4b9b0bcbed14d825a10b91a98d5fed0a" :sha256 "sha256-73b04538821292f5b5e650057d4b37c1c09bc0fce2d8b95883e36b078ab84d33") :dependencies nil :install (:type build :build-system emacs-package :pname "zoutline" :load-paths (".") :features (zoutline)))))

;;; zoutline.el ends here
