;;; popup.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "popup"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/auto-complete/popup-el/tar.gz/7a05700a37aae66d2b24f0cd8851f65383a5cf96" :sha256 "sha256-ac518eb87fa34e756e80ad645032708b50d2beb0545de1b32abc6c473509b2f0") :dependencies nil :install (:type build :build-system emacs-package :pname "popup" :load-paths (".") :features (popup)))))

;;; popup.el ends here
