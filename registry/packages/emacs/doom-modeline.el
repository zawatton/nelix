;;; doom-modeline.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "doom-modeline"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/seagle0128/doom-modeline/tar.gz/9d6f0f9635ae722b6bd943a76e996f54443e373f" :sha256 "sha256-44d56bfb62f9d3a4c4965ccd6eee50324e4f73e6bbb2d8b22df58dead8179e2a") :dependencies nil :install (:type build :build-system emacs-package :pname "doom-modeline" :load-paths (".") :features (doom-modeline)))))

;;; doom-modeline.el ends here
