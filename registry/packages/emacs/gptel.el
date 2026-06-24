;;; gptel.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "gptel"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/karthink/gptel/tar.gz/424c835bc46ed083088e82e2fcd48c2e1c34bacf" :sha256 "sha256-2c1b2d535deeb1817eada1d978ae5e4175db02f1e1436a06bbf7f5c10c5517cd") :dependencies ("transient" "compat") :install (:type build :build-system emacs-package :pname "gptel" :load-paths (".") :features (gptel)))))

;;; gptel.el ends here
