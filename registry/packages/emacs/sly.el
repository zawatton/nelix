;;; sly.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "sly"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/joaotavora/sly/tar.gz/742355f7554ab6c46e5c1c9bdb89068f55359eaa" :sha256 "sha256-ffa627a3f4740372e88990113a2af8178f7bce0771f36b35896f8018b34b6e5f") :dependencies nil :install (:type build :build-system emacs-package :pname "sly" :load-paths (".") :features (sly)))))

;;; sly.el ends here
