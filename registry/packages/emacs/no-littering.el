;;; no-littering.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "no-littering"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/emacscollective/no-littering/tar.gz/35021384cdc1a126b8a6d5fedfd087b5030a993f" :sha256 "sha256-823643f49cb620367eda40f82b2640456895707ac97e9a85c09dcf0a2efec0b1") :dependencies nil :install (:type build :build-system emacs-package :pname "no-littering" :load-paths (".") :features (no-littering)))))

;;; no-littering.el ends here
