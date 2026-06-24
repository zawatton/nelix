;;; rainbow-delimiters.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "rainbow-delimiters"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/Fanael/rainbow-delimiters/tar.gz/7919681b0d883502155d5b26e791fec15da6aeca" :sha256 "sha256-61eb8510bad0d4713f738352307bf6a73c93967ae4c2f369bb4e5b4f91789736") :dependencies nil :install (:type build :build-system emacs-package :pname "rainbow-delimiters" :load-paths (".") :features (rainbow-delimiters)))))

;;; rainbow-delimiters.el ends here
