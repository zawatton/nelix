;;; git-modes.el --- Nelix recipe generated from flake.nix -*- lexical-binding: t; -*-

(require 'nelix-registry)

(nelix-package
 :name "git-modes"
 :version "0.0.0"
 :class 'emacs-package
 :systems '((x86_64-linux :source (:type url :url "https://codeload.github.com/magit/git-modes/tar.gz/f99010bbeb8b6d8a0819fac0195a2ef0159d08f0" :sha256 "sha256-cea6081c4cf23c983bab58405755976a41976da7a8a95b4df2a2e833fb2f028a") :dependencies nil :install (:type build :build-system emacs-package :pname "git-modes" :load-paths (".") :features (git-modes)))))

;;; git-modes.el ends here
